// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-22
package top.cabinplay.direlay.logs

import org.junit.Assert.*
import org.junit.Test
import top.cabinplay.direlay.admin.AdminAuth
import top.cabinplay.direlay.admin.AdminAuthState
import top.cabinplay.direlay.admin.AdminHotspot
import top.cabinplay.direlay.admin.AdminPasswordHash
import top.cabinplay.direlay.settings.WirelessNetworkSettings

class LogHardeningTest {
    @Test fun secretDataClassesNeverPrintTheirSecretFields() {
        val secret = "do-not-print-this-value"
        val values = listOf(AdminHotspot("MyWiFi", secret, "192.168.1.1", true), AdminAuth.Login(secret),
            AdminAuthState(AdminPasswordHash(secret, secret), mapOf(secret to 123L)), WirelessNetworkSettings(manualPassphrase = secret))
        values.forEach { value -> assertFalse(value.javaClass.simpleName, value.toString().contains(secret)) }
    }
}
