// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-22
package top.cabinplay.direlay.relay

interface RelayKeepAlive {
    val state: top.cabinplay.direlay.path.KeepAliveState get() = top.cabinplay.direlay.path.KeepAliveState.NOT_NEEDED
    fun update(needed: Boolean)
    fun uiVisible()

    object None : RelayKeepAlive {
        override fun update(needed: Boolean) = Unit
        override fun uiVisible() = Unit
    }
}
