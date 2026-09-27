# Phase 08 Proposal: Quality of Life & UI Enhancements

Date: 2026-09-27

## Overview
This phase focuses on introducing several quality-of-life automation features and UI enhancements tailored to the combined bag experience and Gamepad UI (Alpha).

## Features

### 1. Auto-Sort Bags
*   **Description**: Automatically trigger the built-in "Clean Bags" functionality to keep the inventory organized without manual intervention.
*   **Behavior & Rules**:
    *   Triggers when the combined bag is **closed** (rather than opened).
    *   Implements an internal 60-second cooldown (it will execute no more than once per minute) to avoid excessive sorting and potential UI stutter.

### 2. Auto-Vend Greys
*   **Description**: Automatically sell all grey (poor) quality items in the inventory when interacting with a merchant.
*   **Behavior & Rules**:
    *   Sells all grey items with no exceptions required.
    *   Integrates with the newly proposed Toast Window (Feature 4). Once the transaction is complete, a toast notification will display the total amount of money gained from the vended items.

### 3. Equipped Skills Window
*   **Description**: A small, dynamic informational panel that displays the player's most relevant current skills. 
*   **Design & Layout**:
    *   Visually matches the existing "Damage Breakdown Panel".
    *   Tethered directly to the left side of `ContainerFrameCombinedBags`.
    *   Visibility is directly tied to the combined bag (shows when opened, hides when closed).
    *   Each row will feature the skill's icon and a simple text representation of the level (e.g., `38 / 40`).
*   **Data Displayed**:
    *   **Primary Professions**: Dynamically displays 0, 1, or 2 primary professions depending on what the player has learned.
    *   **Equipped Weapon Skill**: Displays the skill level specific to the weapon currently equipped (e.g., Two-Handed Swords). Skills for unequipped weapon types are hidden.
    *   **Defense**: Displays the player's current Defense skill level.

### 4. Loot & System Toast Notifications
*   **Description**: Enable pop-up toast notifications for significant events, specifically when looting money, green-quality (or above) gear, and quest items.
*   **Behavior & Rules**:
    *   Primarily intended to restore/enable this functionality for Blizzard's Gamepad UI (Alpha).
    *   **Discovery/Spike Required**: Initial work will involve investigating why Blizzard's native `LootAlertSystem` or `BossBanner` toast windows are failing to display while using the Gamepad UI.
    *   **Fallback Solution**: If the native Blizzard toast window cannot be reliably forced to appear, a lightweight custom toast window will be built as a backup. This fallback will mimic the standard Blizzard aesthetic.
    *   As noted in Feature 2, this toast system will also be utilized to display auto-vend profit summaries.
