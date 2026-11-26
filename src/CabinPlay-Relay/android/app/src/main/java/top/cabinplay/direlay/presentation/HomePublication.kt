// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-25
package top.cabinplay.direlay.presentation

import top.cabinplay.direlay.path.ConnectionPath
import top.cabinplay.direlay.path.PathInput
import top.cabinplay.direlay.ui.HomeContent

internal fun publishHome(input: PathInput, path: ConnectionPath, content: HomeContent): HomeContent =
    content.copy(pathInput = input.copy(nowMillis = 0), path = path)
