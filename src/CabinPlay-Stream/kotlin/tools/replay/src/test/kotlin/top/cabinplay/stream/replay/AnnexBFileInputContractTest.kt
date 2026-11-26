// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-14

package top.cabinplay.stream.replay

import top.cabinplay.stream.core.ProjectionInput
import top.cabinplay.stream.core.ProjectionInputContract

public class AnnexBFileInputContractTest : ProjectionInputContract() {
    override fun createInput(): ProjectionInput = AnnexBFileInput(clipBytes(), frameRate = 100.0)
    override fun stimulate(input: ProjectionInput) {
        // The producer is autonomous; allow frames while running and exercise the stop fence otherwise.
        Thread.sleep(80)
    }
    override fun awaitIdle() { Thread.sleep(40) }
}
