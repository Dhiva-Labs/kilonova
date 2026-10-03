//! Payment pushes from a self-hosted server (see `tools/selfhost`).
//!
//! `push-register` on the server prints a code naming a random topic on the
//! server's ntfy. A push on that topic says only "something arrived for
//! this topic"; the wallet then syncs to see what. Desktops poll the topic
//! here; phones bind a `UnifiedPush` topic to it at the server's relay, which
//! listens on the same host as ntfy, port [`RELAY_PORT`].

use serde::Deserialize;

use crate::SyncError;
use crate::node::{Circuit, NodeUrl, http_client, percent_decode, read_limited};

/// Where the kit's relay accepts `UnifiedPush` bindings, on ntfy's host.
pub const RELAY_PORT: u16 = 8090;

/// A wallet's push topic, from the code `push-register` prints:
/// `kilonova-push:?topic=<topic>&server=<ntfy url>`. `server` may be left
/// out when the pairing code named it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushCode {
    pub topic: String,
    pub server: Option<NodeUrl>,
}

impl PushCode {
    /// Reads a code, or a bare topic.
    ///
    /// # Errors
    ///
    /// [`SyncError::BadNodeUrl`] for anything else.
    pub fn parse(text: &str) -> Result<Self, SyncError> {
        let text = text.trim();
        let Some(query) = text.strip_prefix("kilonova-push:") else {
            return if is_topic(text) {
                Ok(Self {
                    topic: text.to_owned(),
                    server: None,
                })
            } else {
                Err(SyncError::BadNodeUrl)
            };
        };
        let mut topic = None;
        let mut server = None;
        for pair in query.trim_start_matches('?').split('&') {
            let Some((key, value)) = pair.split_once('=') else {
                continue;
            };
            let value = percent_decode(value).ok_or(SyncError::BadNodeUrl)?;
            match key {
                "topic" if is_topic(&value) => topic = Some(value),
                "topic" => return Err(SyncError::BadNodeUrl),
                "server" => server = Some(NodeUrl::parse(&value)?),
                _ => {}
            }
        }
        Ok(Self {
            topic: topic.ok_or(SyncError::BadNodeUrl)?,
            server,
        })
    }
}

/// ntfy's rule for topic names, with a floor on length: topics are secrets
/// here, so short guessable ones are refused.
#[must_use]
pub fn is_topic(text: &str) -> bool {
    (16..=64).contains(&text.len())
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn parse_url(url: &str) -> Result<reqwest::Url, SyncError> {
    reqwest::Url::parse(url).map_err(|_| SyncError::BadNodeUrl)
}

/// The relay next to `server`'s ntfy.
///
/// # Errors
///
/// [`SyncError::BadNodeUrl`] if `server` has no host.
pub fn relay_url(server: &NodeUrl) -> Result<NodeUrl, SyncError> {
    let url = parse_url(server.as_str())?;
    let host = url.host_str().ok_or(SyncError::BadNodeUrl)?;
    NodeUrl::parse(&format!("{}://{host}:{RELAY_PORT}", url.scheme()))
}

/// The ntfy topic of a `UnifiedPush` endpoint, if the endpoint is on
/// `server` (`<server>/<topic>?up=1`). An endpoint anywhere else would
/// send pushes through a third party, so it is refused.
///
/// # Errors
///
/// [`SyncError::BadNodeUrl`] for an endpoint elsewhere or not ntfy-shaped.
pub fn endpoint_topic(server: &NodeUrl, endpoint: &str) -> Result<String, SyncError> {
    let server = parse_url(server.as_str())?;
    let endpoint = parse_url(endpoint.trim())?;
    let same = |u: &reqwest::Url| {
        (
            u.host_str()
                .map(|h| h.trim_end_matches('.').to_ascii_lowercase()),
            u.port_or_known_default(),
        )
    };
    if same(&server) != same(&endpoint) {
        return Err(SyncError::BadNodeUrl);
    }
    let prefix = server.path().trim_end_matches('/');
    let topic = endpoint
        .path()
        .strip_prefix(prefix)
        .map(|p| p.trim_matches('/'))
        .ok_or(SyncError::BadNodeUrl)?;
    if is_topic(topic) {
        Ok(topic.to_owned())
    } else {
        Err(SyncError::BadNodeUrl)
    }
}

/// Asks `server`'s relay to repeat pushes for `topic` on the phone's
/// `UnifiedPush` topic `bound` (empty: stop repeating them).
///
/// # Errors
///
/// [`SyncError::Node`] if the relay cannot be reached or does not know the
/// topic, [`SyncError::NeedsProxy`] for an onion without a proxy.
pub async fn bind(
    server: &NodeUrl,
    topic: &str,
    bound: &str,
    circuit: &Circuit,
) -> Result<(), SyncError> {
    let relay = relay_url(server)?;
    let response = http_client(&relay, circuit)?
        .post(format!("{}/bind/{topic}", relay.as_str()))
        .body(bound.to_owned())
        .send()
        .await
        .map_err(|e| SyncError::Node(format!("relay: {e}")))?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(SyncError::Node(format!(
            "relay answered {}",
            response.status()
        )))
    }
}

/// What a poll of a topic found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushPoll {
    /// Pushes since the last poll.
    pub arrived: u32,
    /// What to pass as `since` next time.
    pub since: String,
}

#[derive(Deserialize)]
struct NtfyMessage {
    id: String,
    event: String,
}

/// The pushes on `topic` since `since` (an id from an earlier poll, or a
/// Unix time in seconds).
///
/// # Errors
///
/// [`SyncError::Node`] if ntfy cannot be reached or answers nonsense.
pub async fn poll(
    server: &NodeUrl,
    topic: &str,
    since: &str,
    circuit: &Circuit,
) -> Result<PushPoll, SyncError> {
    if !is_topic(topic) || !since.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(SyncError::BadNodeUrl);
    }
    let base = server.as_str().trim_end_matches('/');
    let response = http_client(server, circuit)?
        .get(format!("{base}/{topic}/json?poll=1&since={since}"))
        .send()
        .await
        .map_err(|e| SyncError::Node(format!("ntfy: {e}")))?;
    if !response.status().is_success() {
        return Err(SyncError::Node(format!(
            "ntfy answered {}",
            response.status()
        )));
    }
    let body = read_limited(response, 256 * 1024).await?;
    parse_poll(&body, since)
}

fn parse_poll(body: &[u8], since: &str) -> Result<PushPoll, SyncError> {
    let mut out = PushPoll {
        arrived: 0,
        since: since.to_owned(),
    };
    for line in body.split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
        let message: NtfyMessage = serde_json::from_slice(line)
            .map_err(|_| SyncError::Node("ntfy answered nonsense".into()))?;
        if message.event == "message" && message.id.bytes().all(|b| b.is_ascii_alphanumeric()) {
            out.arrived += 1;
            out.since = message.id;
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ONION: &str = "ciczdlujjvdfuvwndzmqpefmndzxelyh3cbip4eqwet6it3tmuwgh2ad.onion";
    const TOPIC: &str = "kn08da05109b5030ab437d84150b2eccfb";

    #[test]
    fn reads_the_code_push_register_prints() {
        let code = format!("kilonova-push:?topic={TOPIC}&server=http%3A%2F%2F{ONION}");
        let parsed = PushCode::parse(&code).unwrap();
        assert_eq!(parsed.topic, TOPIC);
        assert_eq!(parsed.server.unwrap().as_str(), format!("http://{ONION}"));

        let bare = PushCode::parse(&format!("kilonova-push:?topic={TOPIC}")).unwrap();
        assert_eq!(bare.server, None);
        assert_eq!(PushCode::parse(TOPIC).unwrap().topic, TOPIC);

        for bad in [
            "kilonova-push:?server=http%3A%2F%2Fa.onion",
            "kilonova-push:?topic=short",
            "kilonova-push:?topic=kn08da05109b5030ab437d84150b2ecc%2Fx",
            "kilonova-server:?network=mainnet",
            "has spaces in it but is long enough",
        ] {
            assert!(PushCode::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn relay_is_on_the_same_host() {
        let server = NodeUrl::parse(&format!("http://{ONION}")).unwrap();
        assert_eq!(
            relay_url(&server).unwrap().as_str(),
            format!("http://{ONION}:8090")
        );
    }

    #[test]
    fn endpoints_must_be_on_the_own_server() {
        let server = NodeUrl::parse(&format!("http://{ONION}")).unwrap();
        assert_eq!(
            endpoint_topic(&server, &format!("http://{ONION}/upAbCdEfGhIjKlMn12?up=1")).unwrap(),
            "upAbCdEfGhIjKlMn12"
        );
        for bad in [
            "https://ntfy.sh/upAbCdEfGhIjKlMn12?up=1".to_owned(),
            format!("http://{ONION}:8080/upAbCdEfGhIjKlMn12?up=1"),
            format!("http://{ONION}/up/AbCdEfGhIjKlMn12"),
            format!("http://{ONION}/upX"),
        ] {
            assert!(endpoint_topic(&server, &bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn counts_messages_and_remembers_the_last() {
        let body = br#"{"id":"open1","event":"open","topic":"t"}
{"id":"8evdsqJgVSqY","time":1,"event":"message","topic":"t","message":"t"}
{"id":"lL8W7hat3GJN","time":2,"event":"message","topic":"t","message":"t"}
"#;
        let poll = parse_poll(body, "100").unwrap();
        assert_eq!(poll.arrived, 2);
        assert_eq!(poll.since, "lL8W7hat3GJN");
        assert_eq!(parse_poll(b"", "100").unwrap().since, "100");
        assert!(parse_poll(b"<html>", "1").is_err());
    }
}
