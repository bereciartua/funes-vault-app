# DNS for funesvault.com (Hover)

The records to add in Hover's control panel (**funesvault.com ▸ DNS**) for the website and the MCP Registry (email is deferred; see step 4). Hover's nameservers (`ns1.hover.com`, `ns2.hover.com`) must be the domain's nameservers; if they aren't, add the same records wherever the DNS is hosted.

This file sits next to the site for reference; the Pages workflow leaves `.md` files out of what it publishes.

## Order

GitHub's docs ask for this order, so no one else can claim the domain on GitHub Pages in between:

1. **Verify the domain for the account** (step 1 below), and wait until GitHub shows it as verified.
2. **Set the custom domain in the repository**: Settings ▸ Pages ▸ Build and deployment ▸ Source: **GitHub Actions**, then Custom domain: `funesvault.com`.
3. **Add the website records** (step 2), then wait for **Enforce HTTPS** to become available (up to 24 hours) and turn it on.
4. **Add the MCP Registry TXT record** (step 3) any time before the first registry publish.
5. Email forwarding (step 4) is **deferred**: v0.1 has no email addresses.

Also **remove Hover's default records** for the apex and `www` (Hover adds parking A and CNAME records, and sometimes a `*` wildcard). GitHub warns that a wildcard record lets anyone take over subdomains, even with a verified domain.

## 1. GitHub Pages domain verification

At **github.com ▸ your profile picture ▸ Settings ▸ Pages ▸ Add a domain**, enter `funesvault.com`. GitHub then shows a TXT record. Add it, then click **Verify**, and keep the record afterwards (GitHub rechecks it).

| Type | Host | Value | TTL |
|---|---|---|---|
| TXT | `_github-pages-challenge-bereciartua` | the value GitHub shows (a random string) | default |

The full name is `_github-pages-challenge-bereciartua.funesvault.com`; Hover appends the domain to the host. Check it with:

```sh
dig _github-pages-challenge-bereciartua.funesvault.com +nostats +nocomments +nocmd TXT
```

## 2. The website (GitHub Pages)

| Type | Host | Value | TTL |
|---|---|---|---|
| A | `@` | `185.199.108.153` | default |
| A | `@` | `185.199.109.153` | default |
| A | `@` | `185.199.110.153` | default |
| A | `@` | `185.199.111.153` | default |
| AAAA | `@` | `2606:50c0:8000::153` | default |
| AAAA | `@` | `2606:50c0:8001::153` | default |
| AAAA | `@` | `2606:50c0:8002::153` | default |
| AAAA | `@` | `2606:50c0:8003::153` | default |
| CNAME | `www` | `bereciartua.github.io` | default |

- The `www` CNAME points at the account's Pages domain, without the repository name. GitHub then redirects `www.funesvault.com` to `funesvault.com`.
- Check: `dig funesvault.com +noall +answer -t A`, `dig funesvault.com +noall +answer -t AAAA`, `dig www.funesvault.com +noall +answer`.
- Pages for a **private** repository needs a paid GitHub plan. If the repository is still private at this point, either make it public first or check the plan.

These addresses are from GitHub's [Managing a custom domain for your GitHub Pages site](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site) (checked 17 October 2026).

## 3. MCP Registry namespace (`com.funesvault`)

The registry name `com.funesvault/funes` is proved with an Ed25519 key whose public half is in a TXT record **on the apex**. Not `_mcp-auth` or any other subdomain: the registry only looks at `funesvault.com` itself.

| Type | Host | Value | TTL |
|---|---|---|---|
| TXT | `@` | `v=MCPv1; k=ed25519; p=<base64 public key>` | default |

Make the key once, on your Mac, with OpenSSL 3 (macOS's own `openssl` is LibreSSL, which has no Ed25519):

```sh
brew install openssl@3
ossl="$(brew --prefix openssl@3)/bin/openssl"
"$ossl" genpkey -algorithm Ed25519 -out key.pem
# The TXT record's value:
echo "v=MCPv1; k=ed25519; p=$("$ossl" pkey -in key.pem -pubout -outform DER | tail -c 32 | base64)"
# The private key for mcp-publisher (64 hex characters), for the MCP_REGISTRY_DNS_KEY secret:
"$ossl" pkey -in key.pem -noout -text | grep -A3 "priv:" | tail -n +2 | tr -d ' :\n'
```

Then:

- Store the hex private key as the secret `MCP_REGISTRY_DNS_KEY` in the repository's `registry` environment (`gh secret set MCP_REGISTRY_DNS_KEY --env registry --repo bereciartua/funes-vault-app`), keep `key.pem` in a password manager, and delete the file. `.github/workflows/mcp-registry.yml` logs in with `mcp-publisher login dns --domain funesvault.com --private-key <hex>`.
- Check the record: `dig funesvault.com +short TXT`.
- If you ever rotate the key, **delete the old TXT record**: the registry tries a stale one first and fails with a generic signature error.
- The apex can hold other TXT records too (an SPF record, other verifications); they don't interfere.

Format and commands from the registry's [authentication guide](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/authentication.mdx) (DNS authentication; checked 17 October 2026, `mcp-publisher` 1.8.1).

## 4. Email: support@ and security@ (deferred)

**Not set up for v0.1** (decided 18 October 2026): Hover's forwards are a paid add-on, so support goes through GitHub Issues and security reports through GitHub's private vulnerability reporting. If email is added later, use this section (or a free forwarding service such as ImprovMX or Forward Email, naming it in the privacy statement instead of Hover), and put the addresses back in SECURITY.md, PRIVACY.md and the site's privacy and support pages.

Hover's **email forwards** pass mail for an address at the domain on to an existing mailbox. In Hover: **funesvault.com ▸ Email ▸ +**, choose a forward, and create:

| Forward | Delivers to |
|---|---|
| `support@funesvault.com` | your personal mailbox |
| `security@funesvault.com` | your personal mailbox |

Hover's forwards need this MX record. With Hover's nameservers it's usually added for you when you create the first forward; check it's there, and that no other MX record is:

| Type | Host | Value | Priority | TTL |
|---|---|---|---|---|
| MX | `@` | `mx.hover.com.cust.hostedemail.com` | 10 | default (15 min) |

- Source: Hover's [Buying and managing your email accounts](https://support.hover.com/support/solutions/articles/201000064756-buying-and-managing-your-email-accounts) (checked 17 October 2026). It lists that value for Hover email in general and doesn't separate forwards from mailboxes, so confirm in Hover's Email panel after creating the forwards.
- A forward can't send. Replies go out from your personal address, so the person you answer sees it. If that matters, add a mailbox instead, or set up "send as" with a provider that can send for the domain (that needs SPF and DKIM records for that provider).
- Test both addresses from another account before SECURITY.md and the site go live.
- Optional, while the domain sends no mail of its own: a TXT record `v=spf1 -all` on `@` and a TXT record `v=DMARC1; p=reject` on `_dmarc` tell receivers that mail claiming to be from funesvault.com is forged. Remove or change them before you ever send from the domain.

## 5. Optional: funesvault.app

Hover's own domain forwarding only redirects over plain HTTP, and every `.app` domain is HTTPS-only in browsers (HSTS preload), so Hover's forwarding can't redirect `funesvault.app`. If you want it:

- **A second GitHub Pages site**: a tiny public repository (for example `bereciartua/funesvault-app-redirect`) whose `index.html` and `404.html` redirect to `https://funesvault.com` (a `<meta http-equiv="refresh">` plus `<link rel="canonical">`), with custom domain `funesvault.app`. Give `funesvault.app` the same A and AAAA records as step 2, a `www` CNAME to `bereciartua.github.io`, and verify `funesvault.app` for the account as in step 1. GitHub then issues its HTTPS certificate.
- Or point it at a redirect service that issues certificates.

Otherwise, leave it parked; nothing depends on it.
