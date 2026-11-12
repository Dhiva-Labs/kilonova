//! monero-oxide's daemon client over the browser's `fetch`.
//!
//! The desktop transport (kn-sync's `Http`) adds Tor circuits and TLS
//! pinning, neither of which a browser lets an extension do. What carries
//! over: a whole-request timeout, no credentials, and responses cut off at
//! the size limit instead of buffered.

use std::future::Future;

use js_sys::{Promise, Reflect, Uint8Array};
use kn_sync::NodeUrl;
use monero_daemon_rpc::HttpTransport;
use monero_interface::InterfaceError;
use send_wrapper::SendWrapper;
use wasm_bindgen::{JsCast, JsValue, prelude::wasm_bindgen};
use wasm_bindgen_futures::JsFuture;
use web_sys::{
    AbortSignal, ReadableStreamDefaultReader, Request, RequestCache, RequestCredentials,
    RequestInit, RequestRedirect, Response,
};

/// Same as the desktop client's overall timeout.
const TIMEOUT_MS: u32 = 120_000;

#[wasm_bindgen]
extern "C" {
    /// The global `fetch`, in a page or a service worker alike.
    #[wasm_bindgen(js_name = fetch)]
    fn global_fetch(request: &Request) -> Promise;
}

/// A node's RPC endpoint, reached with `fetch`.
#[derive(Clone)]
pub(crate) struct Fetch {
    base: String,
}

impl Fetch {
    pub(crate) fn new(node: &NodeUrl) -> Self {
        Self {
            base: node.as_str().to_owned(),
        }
    }
}

impl HttpTransport for Fetch {
    fn post(
        &self,
        route: &str,
        body: Vec<u8>,
        response_size_limit: Option<usize>,
    ) -> impl Send + Future<Output = Result<Vec<u8>, InterfaceError>> {
        SendWrapper::new(post(
            format!("{}/{route}", self.base),
            body,
            response_size_limit,
        ))
    }
}

fn failure(what: &str, error: &JsValue) -> InterfaceError {
    let detail = error
        .dyn_ref::<js_sys::Error>()
        .map_or_else(|| format!("{error:?}"), |e| String::from(e.message()));
    InterfaceError::InterfaceError(format!("{what}: {detail}"))
}

async fn post(url: String, body: Vec<u8>, limit: Option<usize>) -> Result<Vec<u8>, InterfaceError> {
    let init = RequestInit::new();
    init.set_method("POST");
    init.set_body(&Uint8Array::from(body.as_slice()));
    init.set_signal(Some(&AbortSignal::timeout_with_u32(TIMEOUT_MS)));
    init.set_credentials(RequestCredentials::Omit);
    init.set_cache(RequestCache::NoStore);
    // A node that redirects is not the node the user chose.
    init.set_redirect(RequestRedirect::Error);
    let request =
        Request::new_with_str_and_init(&url, &init).map_err(|e| failure("bad request", &e))?;

    let response: Response = JsFuture::from(global_fetch(&request))
        .await
        .map_err(|e| failure("request failed", &e))?
        .dyn_into()
        .map_err(|e| failure("unexpected fetch result", &e))?;
    if !response.ok() {
        return Err(InterfaceError::InterfaceError(format!(
            "node answered HTTP {}",
            response.status()
        )));
    }
    let Some(stream) = response.body() else {
        return Ok(Vec::new());
    };
    let reader: ReadableStreamDefaultReader = stream
        .get_reader()
        .dyn_into()
        .map_err(|e| failure("unexpected response body", &e))?;

    // Read in chunks so an oversized response is cut off, not buffered.
    let mut out = Vec::new();
    loop {
        let chunk = JsFuture::from(reader.read())
            .await
            .map_err(|e| failure("reading response", &e))?;
        if Reflect::get(&chunk, &"done".into()).is_ok_and(|d| d.is_truthy()) {
            return Ok(out);
        }
        let bytes: Uint8Array = Reflect::get(&chunk, &"value".into())
            .and_then(JsCast::dyn_into)
            .map_err(|e| failure("reading response", &e))?;
        let start = out.len();
        out.resize(start + bytes.length() as usize, 0);
        bytes.copy_to(&mut out[start..]);
        if limit.is_some_and(|limit| out.len() > limit) {
            let _ = reader.cancel();
            return Err(InterfaceError::InvalidInterface(
                "response larger than allowed".into(),
            ));
        }
    }
}
