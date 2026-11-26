// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-27
package top.cabinplay.direlay.ui

import android.os.Build
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import top.cabinplay.direlay.R
import top.cabinplay.direlay.presentation.CarScreenView
import top.cabinplay.direlay.publicname.hasTrustedNameConfiguration
import top.cabinplay.direlay.settings.*
import top.cabinplay.direlay.ui.design.*

@Composable fun TeslaBrowserSettings(draft: RelaySettings, view: CarScreenView, wireless: (RelaySettings) -> Boolean,
    openTrustedHttps: () -> Unit, openOutput: () -> Unit, change: (RelaySettings) -> Unit) {
    val name = view.publicName
    SettingsGroup("tesla", R.drawable.symbol_car, IconHue.CAR, stringResource(R.string.tesla_title),
        stringResource(teslaBrowserOption(draft.teslaBrowser).title), initiallyExpanded = true) {
        Hint(stringResource(R.string.tesla_intro))
        Column(Modifier.selectableGroup()) {
            teslaBrowserOptions.forEach { (mode, option) ->
                RadioOptionRow(option, draft.teslaBrowser == mode,
                    supportingText = if (mode == TeslaBrowserMode.OFF) ""
                        else stringResource(option.supporting, draft.copy(teslaBrowser = mode).teslaAddress().orEmpty())) {
                    change(draft.copy(teslaBrowser = mode))
                }
            }
        }
        val address = draft.teslaAddress()
        if (address != null) {
            if (TeslaAddressPolicy.needsAndroid13Warning(Build.VERSION.SDK_INT, address))
                Hint(stringResource(R.string.tesla_address_android13))
            SettingsGroup("teslaAddress", R.drawable.symbol_globe, IconHue.NETWORK, stringResource(R.string.tesla_address), address) {
                val phoneAddresses = view.phoneAddresses
                SettingField(stringResource(R.string.tesla_address), address,
                    R.string.tesla_address_invalid.takeUnless { TeslaAddressPolicy.valid(address, phoneAddresses) }) {
                    change(when (draft.teslaBrowser) {
                        TeslaBrowserMode.OFF -> draft
                        TeslaBrowserMode.VIRTUAL_NAME -> draft.copy(teslaVirtualAddress = it)
                        TeslaBrowserMode.PUBLIC_ADDRESS -> draft.copy(teslaPublicAddress = it)
                        TeslaBrowserMode.TESLAMIRROR -> draft.copy(teslaMirrorAddress = it)
                        TeslaBrowserMode.TESLA_ANDROID -> draft.copy(teslaAndroidAddress = it)
                    })
                }
            }
            Hint(stringResource(R.string.tesla_requirements))
            if (!draft.browserOutput) {
                Hint(stringResource(R.string.tesla_needs_browser))
                TextButton(onClick = openOutput, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.tesla_open_output))
                }
            }
            if (!wireless(draft)) Hint(stringResource(R.string.tesla_needs_wireless))
            if (draft.wirelessNetwork.choice == WirelessNetworkChoice.EXISTING_WIFI)
                Hint(stringResource(R.string.tesla_needs_phone_network))
            if (draft.teslaBrowser.usesTrustedName && !name.hasTrustedNameConfiguration()) {
                Hint(stringResource(R.string.tesla_needs_name))
                TextButton(onClick = openTrustedHttps, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.tesla_open_name))
                }
            }
        }
    }
}
