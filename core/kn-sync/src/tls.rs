//! TLS for nodes and light wallet servers. By default a server must present
//! a certificate from a public authority (Mozilla's list). A user running
//! their own node with a self-signed certificate can pin it instead: that
//! node is then trusted for exactly that certificate and nothing else.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use rustls::client::WebPkiServerVerifier;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{WebPkiSupportedAlgorithms, verify_tls12_signature, verify_tls13_signature};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{
    CertificateError, ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme,
};

use crate::SyncError;
use crate::node::{NodeUrl, proxy};

/// SHA-256 of a DER certificate.
pub type Fingerprint = [u8; 32];

static PINS: RwLock<Option<HashMap<String, Fingerprint>>> = RwLock::new(None);

/// Replaces the pinned certificates. Only `https` addresses use them.
pub fn set_pins(pins: impl IntoIterator<Item = (NodeUrl, Fingerprint)>) {
    *PINS.write().unwrap_or_else(PoisonError::into_inner) = Some(
        pins.into_iter()
            .map(|(url, pin)| (url.as_str().to_owned(), pin))
            .collect(),
    );
}

fn pin_for(target: &NodeUrl) -> Option<Fingerprint> {
    PINS.read()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()?
        .get(target.as_str())
        .copied()
}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Arc::new(rustls::crypto::ring::default_provider())
}

fn roots() -> Arc<RootCertStore> {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    Arc::new(roots)
}

/// The TLS settings for requests to `target`.
pub(crate) fn config_for(target: &NodeUrl) -> ClientConfig {
    let provider = provider();
    let builder = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions");
    match pin_for(target) {
        Some(pin) => builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(Pinned {
                pin,
                algorithms: provider.signature_verification_algorithms,
            }))
            .with_no_client_auth(),
        None => builder
            .with_root_certificates(roots())
            .with_no_client_auth(),
    }
}

/// # Panics
///
/// Never: SHA-256 digests are 32 bytes.
#[must_use]
pub fn fingerprint(der: &[u8]) -> Fingerprint {
    ring::digest::digest(&ring::digest::SHA256, der)
        .as_ref()
        .try_into()
        .expect("SHA-256 is 32 bytes")
}

/// Accepts exactly one certificate, whatever its issuer or name.
#[derive(Debug)]
struct Pinned {
    pin: Fingerprint,
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if fingerprint(end_entity) == self.pin {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// What a server's certificate is, and whether a public authority vouches
/// for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CertificateInfo {
    pub fingerprint: Fingerprint,
    pub publicly_trusted: bool,
}

/// Records the certificate a server presents, then fails the handshake so
/// nothing is sent over a connection nobody has vouched for.
#[derive(Debug)]
struct Capture {
    seen: Arc<Mutex<Option<CertificateInfo>>>,
    public: Arc<WebPkiServerVerifier>,
}

impl ServerCertVerifier for Capture {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let publicly_trusted = self
            .public
            .verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
            .is_ok();
        *self.seen.lock().unwrap_or_else(PoisonError::into_inner) = Some(CertificateInfo {
            fingerprint: fingerprint(end_entity),
            publicly_trusted,
        });
        Err(rustls::Error::InvalidCertificate(
            CertificateError::ApplicationVerificationFailure,
        ))
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("certificate capture only".into()))
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("certificate capture only".into()))
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Connects to an `https` server only far enough to see its certificate,
/// through the proxy if one is set. Sends no request.
///
/// # Errors
///
/// [`SyncError::BadNodeUrl`] for a plain `http` address,
/// [`SyncError::Node`] if no certificate could be read.
///
/// # Panics
///
/// Never: ring supports the default TLS versions.
pub async fn server_certificate(url: &NodeUrl) -> Result<CertificateInfo, SyncError> {
    if !url.as_str().starts_with("https://") {
        return Err(SyncError::BadNodeUrl);
    }
    let provider = provider();
    let public = WebPkiServerVerifier::builder_with_provider(roots(), provider.clone())
        .build()
        .map_err(|e| SyncError::Node(format!("TLS: {e}")))?;
    let seen = Arc::new(Mutex::new(None));
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Capture {
            seen: seen.clone(),
            public,
        }))
        .with_no_client_auth();
    let builder = match proxy() {
        Some(p) => reqwest::Client::builder()
            .proxy(reqwest::Proxy::all(p.as_str()).map_err(|_| SyncError::BadProxyUrl)?),
        None if url.is_onion() => return Err(SyncError::NeedsProxy),
        None => reqwest::Client::builder().no_proxy(),
    };
    let client = builder
        .tls_backend_preconfigured(config)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(30))
        .user_agent("")
        .build()
        .map_err(|e| SyncError::Node(format!("could not set up HTTP: {e}")))?;
    // The handshake fails on purpose once the certificate is recorded.
    let _ = client.get(url.as_str()).send().await;
    let info = *seen.lock().unwrap_or_else(PoisonError::into_inner);
    info.ok_or_else(|| SyncError::Node("the server presented no certificate".into()))
}
