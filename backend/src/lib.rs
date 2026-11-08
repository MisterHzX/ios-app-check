use std::ffi::{CStr, CString, c_char};
use std::io::Cursor;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use idevice::RsdService;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use plist::{Dictionary, Value};
use serde::Serialize;
use tokio::net::TcpStream;

#[derive(Serialize)]
struct App {
    id: String,
    name: String,
    apple_id: Option<String>,
}

fn field<'a>(dict: &'a Dictionary, key: &str) -> Option<&'a str> {
    dict.get(key)?.as_string().map(str::trim).filter(|s| !s.is_empty())
}

fn app_record(value: Value) -> Option<App> {
    let app = value.into_dictionary()?;
    let id = field(&app, "CFBundleIdentifier")?;
    let metadata = match app.get("iTunesMetadata") {
        Some(Value::Data(data)) => Value::from_reader(Cursor::new(data))
            .ok()
            .and_then(Value::into_dictionary),
        Some(Value::Dictionary(dict)) => Some(dict.clone()),
        _ => None,
    };
    let apple_id = metadata
        .as_ref()
        .and_then(|dict| dict.get("com.apple.iTunesStore.downloadInfo"))
        .and_then(Value::as_dictionary)
        .and_then(|dict| dict.get("accountInfo"))
        .and_then(Value::as_dictionary)
        .and_then(|dict| field(dict, "AppleID"));
    let name = field(&app, "CFBundleDisplayName")
        .or_else(|| metadata.as_ref().and_then(|dict| field(dict, "itemName")))
        .or_else(|| field(&app, "CFBundleName"))
        .unwrap_or(id);

    Some(App { id: id.into(), name: name.into(), apple_id: apple_id.map(str::to_owned) })
}

async fn scan(path: &str, address: &str) -> Result<Vec<App>, String> {
    let remote = address.parse::<SocketAddr>().map_err(|_| "请输入 IPv4 地址和端口，例如 10.7.0.1:49152。")?;
    let bytes = std::fs::read(path).map_err(|_| "无法读取配对文件。")?;
    let mut pairing = RpPairingFile::from_bytes(&bytes)
        .map_err(|_| "需要 Remote Pairing 文件，请勿使用普通 Lockdown 配对文件。")?;

    let stream = TcpStream::connect(remote).await
        .map_err(|e| format!("连接失败：{e}。请检查 LocalDevVPN、设备地址和端口。"))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "iOS App Check");
    client.attempt_pair_verify().await.map_err(|e| format!("配对握手失败：{e}"))?;
    client.validate_pairing(&mut pairing).await.map_err(|_| "配对验证失败，请重新生成此 iPhone 的 Remote Pairing 文件。")?;
    let port = client.create_tcp_listener().await.map_err(|e| format!("创建隧道监听器失败：{e}"))?;
    let stream = TcpStream::connect(SocketAddr::new(remote.ip(), port)).await
        .map_err(|e| format!("连接隧道端口失败：{e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key()).await
        .map_err(|e| format!("隧道握手失败：{e}"))?;
    let source = tunnel.info.client_address.parse::<IpAddr>().map_err(|_| "隧道返回的本地地址无效。")?;
    let destination = tunnel.info.server_address.parse::<IpAddr>().map_err(|_| "隧道返回的设备地址无效。")?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), source, destination);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let stream = adapter.connect(rsd_port).await.map_err(|e| format!("连接 RSD 失败：{e}"))?;
    let mut rsd = RsdHandshake::new(stream).await.map_err(|e| format!("RSD 握手失败：{e}"))?;
    let mut proxy = InstallationProxyClient::connect_rsd(&mut adapter, &mut rsd).await
        .map_err(|e| format!("无法连接应用安装服务：{e}"))?;

    let attributes = ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "iTunesMetadata"];
    let mut options = Dictionary::new();
    options.insert("ApplicationType".into(), Value::String("User".into()));
    options.insert("ReturnAttributes".into(), Value::Array(
        attributes.into_iter().map(|name| Value::String(name.into())).collect()
    ));
    let rows = proxy.browse(Some(Value::Dictionary(options))).await
        .map_err(|e| format!("读取应用列表失败：{e}"))?;
    let apps: Vec<_> = rows.into_iter().filter_map(app_record).collect();
    if apps.is_empty() {
        return Err("安装服务没有返回可识别的 App。".into());
    }
    Ok(apps)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn appcheck_scan(path: *const c_char, address: *const c_char) -> *mut c_char {
    let result = (|| -> Result<Vec<App>, String> {
        if path.is_null() || address.is_null() {
            return Err("缺少配对文件或地址。".into());
        }
        let path = unsafe { CStr::from_ptr(path) }.to_str().map_err(|_| "配对文件路径无效。")?;
        let address = unsafe { CStr::from_ptr(address) }.to_str().map_err(|_| "设备地址无效。")?;
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
            .map_err(|e| format!("无法启动查询：{e}"))?;
        runtime.block_on(async {
            tokio::time::timeout(Duration::from_secs(25), scan(path, address)).await
                .map_err(|_| "查询超时，请检查 LocalDevVPN 和远程配对。".to_owned())?
        })
    })();
    let response = match result {
        Ok(apps) => serde_json::json!({ "apps": apps }),
        Err(error) => serde_json::json!({ "error": error }),
    };
    CString::new(response.to_string()).expect("JSON cannot contain literal NUL bytes").into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn appcheck_free(result: *mut c_char) {
    if !result.is_null() {
        drop(unsafe { CString::from_raw(result) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_download_account_from_binary_metadata() {
        let mut account = Dictionary::new();
        account.insert("AppleID".into(), Value::String("example@example.com".into()));
        let mut download = Dictionary::new();
        download.insert("accountInfo".into(), Value::Dictionary(account));
        let mut metadata = Dictionary::new();
        metadata.insert("com.apple.iTunesStore.downloadInfo".into(), Value::Dictionary(download));
        metadata.insert("itemName".into(), Value::String("Example".into()));
        let mut data = Vec::new();
        Value::Dictionary(metadata).to_writer_binary(&mut data).unwrap();

        let mut installed = Dictionary::new();
        installed.insert("CFBundleIdentifier".into(), Value::String("com.example.app".into()));
        installed.insert("iTunesMetadata".into(), Value::Data(data));

        let app = app_record(Value::Dictionary(installed)).unwrap();
        assert_eq!(app.name, "Example");
        assert_eq!(app.apple_id.as_deref(), Some("example@example.com"));
    }

    #[test]
    fn retains_apps_without_account_metadata() {
        let mut installed = Dictionary::new();
        installed.insert("CFBundleIdentifier".into(), Value::String("com.example.app".into()));
        installed.insert("iTunesMetadata".into(), Value::Data(vec![0, 1, 2]));

        let app = app_record(Value::Dictionary(installed)).unwrap();
        assert_eq!(app.name, "com.example.app");
        assert_eq!(app.apple_id, None);
    }
}
