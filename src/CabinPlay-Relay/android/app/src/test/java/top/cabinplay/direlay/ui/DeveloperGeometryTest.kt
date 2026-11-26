// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-21
package top.cabinplay.direlay.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import top.cabinplay.direlay.video.CarlinkCrop
import top.cabinplay.direlay.video.CarlinkGeometry
import top.cabinplay.stream.core.Viewport

class DeveloperGeometryTest {
    @Test fun liveLineShowsWindowCanvasActiveAreaAndCodedPictureInOrder() {
        val geometry = CarlinkGeometry.calculate(1920, 1080, CarlinkCrop(160, 40, 1440, 960),
            Viewport(1532, 1013), Viewport(1280, 720))
        assertEquals(listOf("1532×1013", "1920×1080", "160,40 1440×960", "1280×720"), carlinkGeometryValues(geometry))
    }
}
