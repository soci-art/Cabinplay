// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-15
//! Names and the car-button icon the Linux relay shows to iPhones, head units and browsers. Every
//! name says "Linux" so a Linux relay is never mistaken for the Android app; the car-button tile is
//! the same on both relays.

/// Bluetooth alias and SDP service name, iAP2 and AirPlay device name, mDNS instance and admin title.
pub const DEVICE_NAME: &str = "CabinPlay Linux";
/// Product the device reports as its model.
pub const MODEL: &str = "CabinPlay Relay Linux";
/// Manufacturer reported over iAP2 and AirPlay.
pub const MANUFACTURER: &str = "CabinPlay";
/// Label the iPhone shows with the car-button (OEM) icon on its "back to the car" tile.
pub const OEM_ICON_LABEL: &str = "CabinPlay";
/// Side of the car-button icon in pixels, the size of the icon the Android relay sends.
pub const OEM_ICON_PIXELS: u32 = 192;
/// Opaque square PNG of the car-button icon, rendered from the launcher icon by
/// android/tools/carplay_oem_icon.py.
pub const OEM_ICON_PNG: &[u8] = include_bytes!("../assets/oem-icon.png");
/// Open provisioning hotspot, followed by the last two Wi-Fi MAC octets.
pub const SETUP_SSID_PREFIX: &str = "CabinPlay-Linux-Setup-";
/// CarPlay hotspot ("this device's hotspot" mode), followed by four random uppercase letters/digits.
pub const HOTSPOT_SSID_PREFIX: &str = "CabinPlay-Linux-";
