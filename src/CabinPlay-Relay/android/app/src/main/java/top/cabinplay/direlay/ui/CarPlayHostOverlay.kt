// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-24
package top.cabinplay.direlay.ui

import androidx.compose.runtime.Composable
import top.cabinplay.direlay.path.*

@Composable internal fun HostOverlayScreen(value: HostOverlayPresentation, busy: Boolean,
    onStepAction: (StepAction, PathStep) -> Unit, onRecheck: () -> Unit, onCopy: (String) -> Unit,
    onStartStop: () -> Unit, onRestart: () -> Unit, onSettings: (String) -> Unit, onGuide: () -> Unit,
    onAction: (HostOverlayAction) -> Unit) {
    StageHome(value.path, StageFlags(busy = busy, overlay = true,
        displayChanged = value.displayChanged && value.path.running, carIncomplete = value.carIncomplete,
        setupCompleted = value.setupCompleted), value.receiverUrls, value.problems, onStepAction, onRecheck, onCopy,
        onStartStop = onStartStop, onStop = { onAction(HostOverlayAction.STOP) },
        onBack = { onAction(HostOverlayAction.BACK) }, onRestart = onRestart,
        onSettings = onSettings, onGuide = onGuide, highPerformance = value.highPerformance)
}
