# Duplicate File Finder

A local web app for finding and safely removing duplicate files and folders on Windows, built entirely in PowerShell — no installs, no external dependencies.

> This project was developed with the assistance of Claude AI.

## What it does

- Scans chosen folders (or specific drives) for byte-identical duplicate files.
- Detects whole duplicate folders (not just individual files) — e.g. a backup copy of an entire folder tree — and reports it as one entry instead of one line per file inside it.
- Skips OneDrive "cloud-only" placeholder files, so it never triggers unwanted downloads.
- Lets you search whether one specific file or folder has copies anywhere else, letting you choose exactly where to look.
- Runs as a small local web app: a PowerShell HTTP server on localhost, with an interactive page in your browser.
- Deleting always goes through the Windows Recycle Bin (reversible) and always requires an explicit checkbox selection plus confirmation — nothing is ever deleted automatically.

## Requirements

- Windows with PowerShell (tested on Windows PowerShell 5.1 and PowerShell 7).
- No installs, no admin rights needed.

## Usage

    powershell -ExecutionPolicy Bypass -File .\duplicate_finder_app.ps1

This opens http://localhost:8791/ in your default browser. Keep the PowerShell window open while using the page — it's the engine behind it. Close the window to stop the server.

## Features

- Scan for duplicates — pick preset folders (Desktop, Downloads, Documents, Pictures, shown separately for local vs. OneDrive-backed versions) or browse to any folder/drive with the built-in folder browser.
- Find a specific file/folder — point at one file or folder (browse and pick it directly, files included) and choose where to search for copies of it.
- Results view — grouped by duplicate set, sortable by space wasted / number of copies / path, filterable by text or type (folder vs. file).
- Delete — check any of the copies (at least one must stay checked-out, so you can't wipe every copy), click delete, confirm — items go to the Recycle Bin.
- Show in Explorer — jump straight to a file or folder's location in File Explorer instead of just copying the path.

## Safety notes

- Never deletes permanently — everything goes through the Recycle Bin and can be restored.
- Never opens or downloads OneDrive "cloud-only" files — folders containing them are skipped for that file only, not force-materialized.
- Nothing is deleted without an explicit checkbox selection and a confirmation click.
