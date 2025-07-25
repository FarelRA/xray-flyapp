# All-in-One Tunneling & Proxy Server on Fly.io

This project provides a robust, professionally architected, all-in-one solution for deploying Xray, FRP, and other services on Fly.io. It has been completely rewritten for enhanced stability, manageability, and features, centered around a powerful web-based Admin Dashboard.

Forget brittle shell scripts and manual configuration. This is your personal, self-managed Ngrok/Cloudflare Tunnel alternative, with the power of a full proxy suite, running on the edge.

 <!-- Replace with your diagram image -->

## ✨ What's New in this Version

*   **Powerful Admin Dashboard:** A central UI to manage the entire application.
    *   **Service Control:** Start, stop, and restart services (Xray, FRPS, etc.) with one click.
    *   **Live Configuration Editor:** Edit `frps.toml`, `xray.json`, and `traefik` routing rules directly from your browser. Changes are persistent.
    *   **Real-time Log Streaming:** View logs from any service live.
    *   **Integrated Web Terminal:** Full shell access to your container within the dashboard.
*   **Rock-Solid Process Management:** Replaced the `start.sh` script with **`s6-overlay`**, the industry standard for process supervision in containers.
*   **Intelligent Edge Routing:** Replaced `Nginx` with **`Traefik`**, a modern reverse proxy that dynamically routes traffic to your services.
*   **Persistent State:** Configurations and logs are stored on a persistent Fly.io volume, surviving restarts and redeploys.
*   **Simplified & Secure:** Streamlined Dockerfile, cleaner configuration, and a modular design that's easier to understand and extend.

## 🚀 Deployment

**Prerequisites:**
*   A [Fly.io](https://fly.io/) account.
*   [flyctl](https://fly.io/docs/hands-on/install-flyctl/) installed locally.

### Step 1: Launch the App

1.  **Clone the Repository:**
    ```bash
    git clone <your-repo-url>
    cd <repo-folder>
    ```
2.  **Launch on Fly.io:**
    This command will create the app, create a persistent volume for your data, but **will not deploy it yet**.
    ```bash
    fly launch --copy-config --name farel --no-deploy
    ```
    *   The app name is set to "farel".
    *   Select a primary region.
    *   When prompted to "Create a volume for this app", say **Yes**. This is crucial for persistent configs.

### Step 2: Set Secrets

Set the essential secrets for authentication. Use strong, unique values.

```bash
fly secrets set \
  -a farel \
  DASHBOARD_USER="admin" \
  DASHBOARD_PWD="CHOOSE_A_VERY_STRONG_PASSWORD" \
  FRP_TOKEN="CHOOSE_A_SECURE_FRP_TOKEN" \
  UUID="GENERATE_A_UUID_V4"
```
> You can generate a UUID from a site like [uuidgenerator.net](https://www.uuidgenerator.net/).

### Step 3: Deploy

Now, deploy your application.

```bash
fly deploy -a farel
```

After deployment, Fly.io will provide you with your app's hostname, like `farel.fly.dev`.

### Step 4: Custom Domain Setup (Optional)

This application supports **wildcard domain matching** with automatic TLS certificate management:

#### **Automatic TLS Certificates**
The following domains will automatically get Let's Encrypt certificates:
- `*.farel.fly.dev` (Fly.io default)
- `*.farel.is-a.dev` 
- `*.fly.farel.is-a.dev`
- `*.farel.at.eu.org`
- `*.fly.farel.at.eu.org`

#### **Self-Signed Fallback**
Any other domain will be served with a self-signed certificate, allowing you to add new domains without configuration changes.

#### **Setup Steps:**

1. **Add certificates for your custom domains:**
   ```bash
   fly certs add -a farel farel.is-a.dev
   fly certs add -a farel "*.farel.is-a.dev"
   fly certs add -a farel fly.farel.is-a.dev
   fly certs add -a farel "*.fly.farel.is-a.dev"
   fly certs add -a farel farel.at.eu.org
   fly certs add -a farel "*.farel.at.eu.org"
   fly certs add -a farel fly.farel.at.eu.org
   fly certs add -a farel "*.fly.farel.at.eu.org"
   ```

2. **Configure DNS records** for your domains:
   - **A Record**: Point to your Fly.io app's IPv4 address
   - **AAAA Record**: Point to your Fly.io app's IPv6 address
   - Get these IPs with: `fly ips list -a farel`

3. **Verify certificates:**
   ```bash
   fly certs show -a farel farel.is-a.dev
   ```

#### **Wildcard Routing**
The Traefik configuration uses wildcard patterns:
- `admin.*` → Admin Dashboard
- `frp.*` → FRP Dashboard  
- `api.*` → API endpoints
- `*` + `/vless` → Xray VLESS endpoint
- `*` (fallback) → Main dashboard

This means you can use **any subdomain** with your configured domains, such as:
- `admin.example.com` (with self-signed cert)
- `frp.mydomain.net` (with self-signed cert)
- `admin.farel.is-a.dev` (with Let's Encrypt cert)

## 🛠️ Using the Dashboard

1.  **Access the Dashboard:** Navigate to one of these URLs:
    - `https://admin.farel.fly.dev` (Fly.io default)
    - `https://admin.farel.is-a.dev` (Custom domain)
    - `https://admin.fly.farel.is-a.dev` (Custom domain)
    - `https://admin.farel.at.eu.org` (Custom domain)
    - `https://admin.fly.farel.at.eu.org` (Custom domain)
2.  **Login:** Use the `DASHBOARD_USER` and `DASHBOARD_PWD` you set in the secrets.
3.  **Explore:**
    *   View service status and restart them as needed.
    *   Go to the "Configuration Editor" to inspect or modify `frps.toml` or `xray.json`. After saving, you may need to restart the relevant service for changes to take effect.
    *   Stream logs or open the terminal for advanced debugging.

##  client Configurations

### FRP Client (frpc.toml)

Point your `frpc` to your new server.

```toml
serverAddr = "farel.fly.dev"
serverPort = 7000 # For TCP
# serverPort = 7001 # For KCP (UDP)
# serverPort = 7002 # For QUIC (UDP)

auth.token = "YOUR_FRP_TOKEN_SECRET" # Must match the secret

[[proxies]]
name = "ssh-tunnel"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 2222 # Must match an open port in fly.toml
```

### Xray Client (VLESS over WebSocket)

*   **Address:** `farel.fly.dev` or custom domains (`farel.is-a.dev`, `fly.farel.is-a.dev`, `farel.at.eu.org`, `fly.farel.at.eu.org`)
*   **Port:** `443`
*   **UUID / User ID:** Your `UUID` secret
*   **Protocol / Security:** `none`
*   **Network / Transport:** `ws` (WebSocket)
*   **Path:** `/vless`
*   **TLS/Security:** `tls`
*   **SNI (Server Name Indication):** Use the same domain as Address

## Credits & Acknowledgements

This project stands on the shoulders of giants and is a significant evolution of concepts from:
*   [AnimMouse/frp-flyapp](https://github.com/AnimMouse/frp-flyapp/)
*   [FarelRA/xray-flyapp](https://github.com/FarelRA/xray-flyapp)
*   The creators of Traefik, s6-overlay, FRP, and Xray.
