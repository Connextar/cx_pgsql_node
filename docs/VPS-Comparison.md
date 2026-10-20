# Which VPS: comparison for CX_PGSQL_Node_1

## Decision (2026-10-20): HostHatch, London, Debian 13

The owner chose **HostHatch London on Debian 13**, after a second round of research:

- **The plan:** 16 GB RAM, 4 cores (2 dedicated, 2 fair-shared), 75 GB NVMe, about **$15/month** before tax.
  A 12 GB plan is about $12. That's the most RAM for the money among UK options, and spare RAM is
  what Postgres turns into cache.
- **Why not OVHcloud:** it **showed no UK availability** when ordering. The first round of research
  below recommended its London (Erith) VPS, but the order page didn't offer it.
- **Benchmarks:** HostHatch scored stability **C** on vpsbenchmarks (its 32 GB plan, March 2025) and
  **B** on an older 8 GB test. That's better than Contabo's F, but not a guarantee for this plan.

Before relying on it:

- **Latency to AWS London.** HostHatch's London looking glass (https://lg.lon.hosthatch.com) can ping
  from its network. Try an AWS eu-west-2 endpoint such as `ec2.eu-west-2.amazonaws.com`. Once the
  server is up, also time `SELECT 1` from a Vercel function in `lhr1`.
- **Disk.** 75 GB holds the database, the local pgBackRest repository and the dumps comfortably at
  today's size (about 350 MB), but watch the health endpoint's `disk` check as data grows.
- **Data protection.** Check HostHatch's company jurisdiction and DPA, and where its staff and
  sub-processors are, before children's records go on it.
- **First login.** If the server arrives with a root password only, put your key on it once with
  `ssh-copy-id root@<ip>`. `bin/remote.sh` uses keys only.

Suggested settings for the 16 GB plan: leave `PG_MEMORY_LIMIT=auto` (about 9.6 GB for Postgres) and
`PG_IMAGE_VARIANT=trixie`. The setup is tested on Debian 13 and 12.

---

_The first round of research follows. It recommended OVHcloud, which turned out to have no UK stock._

_Researched 2026-10-20. Prices change: re-check before ordering. £ figures use £1 = €1.189 = $1.334
(xe.com mid-market, 20 Oct 2026). "incl. VAT" = ex-VAT × 1.20. A VAT-registered business reclaims the VAT,
so the ex-VAT column is the real cost._

## What matters for this server

1. **Distance to AWS London.** The first tenant (AltEd) runs on Vercel in `lhr1`, which is AWS
   `eu-west-2`, London. Every page makes many sequential queries, so each extra millisecond of
   round trip is paid dozens of times per page. At 50 queries a page, roughly:

   | Location | Round trip | Network wait per page |
   | --- | --- | --- |
   | London | 1–2 ms | 75–100 ms |
   | Portsmouth | ~4.5 ms | ~220 ms |
   | Worcester | ~7 ms | ~350 ms |
   | Nuremberg | ~14–19 ms | ~900 ms |

   No provider publishes latency *from AWS*. The figures here are single benchmark runs from each VM
   to a London test node (vpsbenchmarks.com YABS), so they are relative, not absolute.

2. **Steady disk and CPU.** It's a database: I/O and CPU consistency matter more than peak numbers.

3. **UK GDPR.** Children's education records, so you need an Art. 28 data processing agreement (DPA) with
   the host. Hosting in the EEA is lawful without extra transfer paperwork (full UK adequacy), but
   US-owned providers need the UK Extension to the EU–US Data Privacy Framework or the IDTA addendum.

4. **Size.** 4 vCPU, 8 GB RAM, ~100 GB NVMe is comfortable for Postgres + PgBouncer + nginx + the health
   service + pgBackRest + n8n (~0.5 GB). Today's database is ~350 MB.

## Recommendation

**First choice: OVHcloud VPS-3 2027, London (Erith).** 6 vCore, 12 GB RAM, 100 GB NVMe, unmetered.
**£10.60/month ex VAT (£12.72 incl.)**, no commitment, or £9.01 ex on 12 months. VPS-2 2027 (4 vCore,
8 GB, 75 GB NVMe) is £7.40 ex (£8.88 incl.) if 75 GB is enough.

- London, measured ~1.9 ms, in the same band as the far dearer US clouds; no UK surcharge.
- Its comparable VPS scored stability A (0.01 % CPU steal) on vpsbenchmarks; Contabo's latest scored F.
- IPv4, IPv6 and anti-DDoS included; a UK-entity Art. 28 DPA (OVH Ltd).
- Daily backup is on a free promotion (1-day retention, same building): treat it as a bonus only. The
  off-site pgBackRest copy in Dropbox is the backup. (OVH's 2021 Strasbourg fire destroyed same-site backups.)

**Runner-up: Akamai/Linode "Linode 8GB", London.** 4 vCPU, 8 GB, 160 GB. $48 ≈ £43 incl. VAT (≈ £52
with backups). Equally close (~1.75 ms), fully verified prices and a DPA built into its terms, but
3–4× OVH. If disk I/O matters most: **UpCloud Premium 4c/8 GB, London** (≈ £52 incl., ~100k read IOPS,
~1.5 ms; price and DPA third-party/by request).

**Contabo Cloud VPS 4 (the £5.18 offer)** is the cheapest, but it is in **Portsmouth** (~4.5 ms,
≈ +125 ms per 50-query page vs London), the £5.18 is the first 24 months only and excludes a UK
location fee, its latest benchmark trial scored stability F, and its disk looked capped at ~2.6k IOPS. Acceptable
only if price beats everything else.

**Before committing:** rent the finalist(s) for a day and time `SELECT 1` round trips from a Vercel
function pinned to `lhr1`. Both OVH and Linode bill monthly/hourly.

## Comparison

| Provider | Plan | Specs | £/mo ex VAT | £/mo incl. VAT | UK location (RTT to London node) | Backups / snapshots | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **OVHcloud** | VPS-3 2027 | 6 vCore, 12 GB, 100 GB NVMe | 10.60 (9.01 on 12 mo) | **12.72** | London/Erith, 1.88 ms | Daily (1 day) free on promo; 7-day £2.14; snapshot £0.61 | DDoS, IPv4/6 included; UK DPA; pick local NVMe at order |
| | VPS-2 2027 | 4 vCore, 8 GB, 75 GB NVMe | 7.40 (6.29) | 8.88 | same | same | disk below target, fine for 350 MB |
| **Akamai/Linode** | Linode 8GB | 4 vCPU, 8 GB, 160 GB | ≈ 35.97 ($48) | 43.17 | London (two regions), 1.75 ms | $10/mo, 14 days | DPA in terms; dedicated CPU ≈ £77 incl. |
| **UpCloud** | Premium 4c/8 GB | 4 vCPU, 8 GB, 100 GB MaxIOPS | ≈ 43.73 (€52, third-party) | ≈ 52.48 | London, 1.46 ms | Simple Backup +10–60 % | best database I/O; DPA on request |
| **Vultr** | High Performance 4c/8 GB | 4 vCPU, 8 GB, 180 GB NVMe | ≈ 35.97 ($48) | 43.17 | London, 1.78 ms | +20 % (2 most recent) | DDoS protection is +$10/mo; DPA by request |
| **DigitalOcean** | Basic 4 vCPU/8 GB | 4 vCPU, 8 GB, 160 GB | ≈ 35.97 ($48) | 43.17 | LON1 (Slough), 3.44 ms | +20–30 % | CPU share not guaranteed on Basic |
| **Krystal** (UK) | Katapult C-8 | 4 vCPU, 8 GB, 125 GB | 51.25 + 2 (IPv4) | ≈ 63.90 | London, 1.15 ms | £0.05/GB-mo | Trustpilot 4.9; confirm DPA covers Katapult |
| **Mythic Beasts** (UK) | VPS 12 + 100 GB + IPv4 | 4 vCPU, 12 GB, 100 GB | 47.00 | 56.40 | London + Cambridge | £4 + 80p/GB | UK-only data; DPA on request |
| **Clouvider** (UK) | VPS.8 | 4 vCPU, 8 GB, 160 GB NVMe | 10.00 (8.80 annual) | 12.00 | London | none mentioned | Trustpilot 2.6, no public DPA |
| **Contabo** | Cloud VPS 4 | 4 vCPU, 8 GB, 100 GB SSD, 200 Mbit/s | 4.32 (24 mo), 5.40 regular, + UK fee | 5.18 + UK fee (≈ £1.2–1.6, unverified) | **Portsmouth**, 4.5 ms | 1 snapshot; auto backup paid | stability F (Sep 2026); DPA must be concluded in panel |
| **IONOS UK** | VPS L+ | 4 vCore, 8 GB, 240 GB NVMe | 7 for 3 mo, then 22; £10 setup | 8.40 → 26.40 | **Worcester**, 6–7 ms | Cloud Backup from £0.045/GB | teaser price; billing complaints |
| **Fasthosts** | VPS 4 | 4 vCPU, 8 GB, 240 GB NVMe | 7 → 22 | ≈ 26.40 | Worcester, 7 ms | add-on | same platform as IONOS |
| **Hostinger** | KVM 2 / KVM 4 | 2/8/100, 4/16/200 | 6.79 → 12.99 / 9.99 → 24.99 (24 mo upfront) | 8.15 → 15.59 / 11.99 → 29.99 | Manchester, 8.4 ms | weekly free | CPU credits throttle to 30 %: poor for a DB |
| **Netcup** | VPS 1000 G12.5 | 4 vCore, 8 GB, 128 GB | ≈ 8.70 (24 mo) | 10.45 | **no UK**, Nuremberg 14–19 ms | snapshots | too far |
| **Hetzner** | CX33 | 4 vCPU, 8 GB, 80 GB | 7.56 | 9.07 | **no UK**, 18–37 ms | +20 % | sold out at EU sites; three 2026 price rises |
| **Scaleway** | DEV1-L + 100 GB | 4 vCPU, 8 GB | ≈ 37.35 | 44.82 | **no UK**, Paris 7.8 ms | snapshots | weak disk benchmark |
| **one.com** | Cloud server M | 4 vCPU, 8 GB, 200 GB (5k IOPS cap) | ≈ $9.99 (third-party) | unverified | **no UK** (Denmark) | paid | skip |

Not verified: Contabo's UK fee, auto-backup and renewal prices; UpCloud's official prices and DPA;
Hetzner's backup prices; one.com prices; Fasthosts' VAT basis; Krystal/Mythic Beasts/Clouvider DPAs;
every AWS-to-provider latency.

### Managed Postgres in London, for contrast

| Service | Smallest sensible plan | ≈ £/mo incl. VAT | Point-in-time recovery / HA |
| --- | --- | --- | --- |
| Neon (today) | Launch, 1 CU always on | 69 | PITR 7 days; scales to zero |
| DigitalOcean Managed PG (LON1) | 4 GiB / 2 vCPU | 55 | PITR 7 days; HA now only on Advanced (≥ $260) |
| Akamai Managed DB (gb-lon) | Shared 4 GB, 1 node | 57 | PITR; 3-node HA option |
| Supabase (eu-west-2) | Pro + Medium | 67 | PITR is +$100/mo |
| Aiven (aws-eu-west-2) | Startup-4 | 99 | PITR 2 days; HA ≈ $290 |
| AWS RDS (eu-west-2) | db.t4g.medium single-AZ | 48 + storage | Multi-AZ ≈ ×2 |

A London VPS at £9–£52 a month is far cheaper; the price is running backups, recovery, upgrades and
failover yourself, which is what this project automates.

## Before ordering

- **OVHcloud:** choose **London** and the **local NVMe** option. Its Debian images usually log in as
  the `debian` user with sudo (root by key disabled): set `BOOTSTRAP_SSH_USER=debian` in
  `config/server.env`. The VPS 2027 range launched June 2026; OVH raised older plans' renewal prices
  in April 2026. Standard support is slow.
- **Contabo:** the £5.18 is the 24-month intro price; renewals are higher, contracts extend by the same
  term, and the DPA must be concluded in the control panel.
- **IONOS/Fasthosts:** £7 is a 3-month teaser, then £22 ex; cancellation is by phone.
- **Every host:** sign its DPA; note where its support staff and sub-processors are.
- **Dropbox** (the backup destination) is a US company: check its DPA and data location for children's
  records. What it holds is encrypted on the server first (pgBackRest's AES-256 key, and age for dumps),
  so Dropbox only ever sees ciphertext.

## Key sources

- Vercel regions (lhr1 = eu-west-2): https://vercel.com/docs/regions
- ICO, adequacy and transfers: https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/international-transfers/adequacy-regulations/is-the-restricted-transfer-covered-by-adequacy-regulations
- OVHcloud VPS UK: https://www.ovhcloud.com/en-gb/vps/ · catalogue API https://api.ovh.com/1.0/order/catalog/public/vps?ovhSubsidiary=GB · DPA https://contract.eu.ovhapis.com/1.0/pdf/OVH_Data_Protection_Agreement-gb.pdf · benchmarks https://www.vpsbenchmarks.com/hosters/ovhcloud
- Akamai/Linode prices https://www.akamai.com/cloud/pricing · API https://api.linode.com/v4/linode/types · DPA https://www.linode.com/legal-dpa/
- UpCloud plans https://upcloud.com/docs/products/cloud-servers/plans/ · calculator https://calc.upcloud.com/cloud-servers?currency=EUR
- Vultr plans API https://api.vultr.com/v2/plans?per_page=500
- DigitalOcean Droplets https://www.digitalocean.com/pricing/droplets · DPA https://www.digitalocean.com/legal/data-processing-agreement
- Contabo https://contabo.com/en/vps/ · UK location https://contabo.com/en/locations/united-kingdom/ · trial https://www.vpsbenchmarks.com/trials/contabo_performance_trial_08Sep2026 · GBP prices https://www.hosttest.co.uk/comparison/contabo-vps-hosting.html
- IONOS UK https://www.ionos.co.uk/servers/vps · Fasthosts https://www.fasthosts.co.uk/virtual-private-servers
- Hostinger https://www.hostinger.com/uk/vps-hosting · Netcup https://www.netcup.com/en/server/vps · Hetzner https://www.hetzner.com/cloud/
- Krystal https://krystal.io/cloud/pricing · Mythic Beasts https://www.mythic-beasts.com/servers/virtual · Clouvider https://www.clouvider.com/vps/
- one.com https://www.one.com/en/vps · Scaleway https://www.scaleway.com/en/pricing/virtual-instances/
- Managed Postgres: https://www.digitalocean.com/pricing/managed-databases · https://aiven.io/pricing?product=pg · https://neon.com/pricing · https://supabase.com/pricing · https://aws.amazon.com/rds/postgresql/pricing/
- Latency (city to city): https://wondernetwork.com/pings/London · benchmark runs: https://www.vpsbenchmarks.com/
