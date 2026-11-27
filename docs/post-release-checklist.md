# Post-release checklist (after v1.0.0)

> **Scope:** features and improvements planned **after `v1.0.0`**, compared against MeshChatX and `rettui`.
> Work scheduled **before** 1.0.0 is tracked in [PLAN.md](PLAN.md) and is not repeated here:
> phase 6 (RNode/LoRa), phase 7 (background + notifications), phase S (device group sync without the
> bridge) and phase V (voice: LXST calls on fast links, Codec2 voice messages on LoRa).
> `v1.0.0` is released only with the owner's explicit approval.

## Messaging & media
- [ ] **LXMF attachments:** send, download and display images, files and audio in chats (today only text and the `attachments` flag are handled; vault sync carries attachment metadata only).
- [ ] **LXMF tickets:** generate and use delivery tickets so stamp-enforcing peers do not need a PoW stamp for every message (incoming ticket fields are ignored today).
- [ ] **Telemetry & maps (optional):** send/receive location telemetry and render offline maps (PMTiles).

## Group chats (RRC)
- [ ] **Native RRC (without the bridge):** connect directly to RRC hubs from the device group identity (today RRC rooms work only through the MeshChatX bridge).
- [ ] **RRC UX:** add/remove hubs and join/leave rooms from the UI, read state (`mark_read`).

## Networking
- [ ] **AutoInterface:** local Wi-Fi / LAN peer discovery via multicast, without a central TCP server.
- [ ] **Closed networks:** IFAC (network name + passphrase) on TCP and RNode interfaces.
- [ ] **More interfaces:** UDP, I2P, KISS-over-TCP (e.g. TNCs).
- [ ] **Transport mode on desktop (optional):** forward traffic and rebroadcast announces for others.
- [ ] **Propagation, advanced:** several nodes at once / node failover lists, stamp at the node's lower bound (flexibility), peering is out of scope (Kestrel stays a client).
- [ ] **Remaining protocol pieces:** Channel/Buffer, GROUP destinations, link-request stamps, paper messages.

## Notifications
- [ ] **iOS real-time push:** only possible with an Apple Developer account (APNs); until then iOS checks are periodic (BGAppRefresh).

## NomadNet browser
- [ ] **Full Micron rendering:** tables, images and partials (today tables are plain monospace text and images show as `[image: alt]`).
- [ ] **`rrc://` links** from pages (open a room once native RRC exists).
