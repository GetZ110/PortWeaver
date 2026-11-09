# PortWeaver

## Platform
Native macOS 14 or later.

## Purpose
A graphical manager for TCP and UDP forwarding rules with IPv4 / IPv6 support and a button to configure the macOS application firewall. Requested as a Mac counterpart to PortProxyGUI.

## Stack
Implementation choice: SwiftUI, Network.framework, Foundation, Swift Package and Xcode project. No third-party runtime.

## Operating decisions
- Inferred audience: developers and operators managing local network services.
- Native Mac interface, Chinese copy, system appearance, keyboard actions.
- Rules are persisted; forwarding runs while the app is open. Closing the window leaves it running. Quitting stops forwarding.
- Automatic firewall setup uses macOS administrator authorization to register and unblock this app. It does not enable the global firewall or override block-all / organization policy.
- Low ports and persistence after quitting are outside this initial app architecture; binding errors must be shown honestly.
- No active forwarding rules on first launch. Example rules are opt-in and disabled.
