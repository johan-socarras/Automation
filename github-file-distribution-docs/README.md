# GitHub File Distribution and Location Reporting System

## Overview

This project provides a PowerShell-based system for distributing a centralized update file from GitHub to multiple remote locations.

> This project was developed with the assistance of ChatGPT.

Each location downloads the latest file, compares it against the existing local copy, updates it only when needed, and sends a daily status report back to GitHub.

This can be used to distribute files such as:

- database update files
- price lists
- product catalogs
- PLU files
- configuration files
- CSV, TXT, JSON, or other operational files

The project also includes a reporting script that helps an administrator confirm which locations completed the update and which ones did not report.

## Main Use Case

The system is designed for environments where one central file needs to be distributed to many locations.

Example workflow:

1. An administrator uploads or updates a file in GitHub.
2. Each remote location runs the download script.
3. The script downloads the file from GitHub.
4. The script compares the downloaded file with the local file using SHA256.
5. If the file is different, the local file is replaced.
6. The location sends a status report to GitHub.
7. The administrator runs the report script to verify which locations reported successfully.

## Scripts

### `scripts/Download-Update.ps1`

This script should run at each remote location.

It performs the following actions:

- downloads the update file from GitHub
- stores the file temporarily
- compares the downloaded file with the local version
- replaces the local file only when a newer or different file is detected
- sends a status report to GitHub
- saves pending reports locally if the report cannot be sent

Possible reported statuses:

```text
File Updated Successfully
File Already Updated
Download Failed
Local File Update Failed
```

### `scripts/Generate-DailyReport.ps1`

This script is used by the administrator to check reporting status.

It performs the following actions:

- reads the master list of expected locations
- checks the daily log folder in GitHub
- compares expected locations against reported locations
- displays locations that did not report
- confirms when all locations reported successfully

## GitHub Log Structure

Each location creates one report file per day.

Recommended log structure:

```text
Log/
└── 2026-06-30/
    ├── LOCATION01.txt
    ├── LOCATION02.txt
    └── LOCATION03.txt
```

Example report file:

```text
SiteID: LOCATION01
Status: File Updated Successfully
Timestamp: 2026-06-30 17:30:00
```

## Requirements

- Windows
- PowerShell 5.1 or newer
- Internet access from each remote location
- GitHub repository
- GitHub token with the minimum permissions required to read files and write status logs

## Configuration

Each location should have its own unique `SiteID`.

Example:

```powershell
$SiteID = "LOCATION01"
```

Common configuration values:

```powershell
$RepoOwner = "your-github-username"
$RepoName  = "your-repository-name"
$Branch    = "main"
$FileName  = "PLU_Update.txt"
```

The GitHub token should be configured as an environment variable:

```powershell
$GitHubToken = $env:GITHUB_TOKEN
```

Do not hardcode GitHub tokens directly inside the scripts.

## Example Usage

Run this script at each remote location:

```powershell
.\scripts\Download-Update.ps1
```

Run this script from the administrator machine to check daily reporting:

```powershell
.\scripts\Generate-DailyReport.ps1
```

## Recommended Improvements

Future improvements could include:

- move the master location list to a CSV or JSON file
- convert fixed script values into parameters
- generate CSV or HTML reports
- send alerts through email or Microsoft Teams
- automate execution with Windows Task Scheduler
- support multiple update files
- validate downloaded files with checksum or digital signature
- add local log files for troubleshooting

## Security Notice

Never commit GitHub tokens, passwords, internal server paths, or confidential business data to the repository.

If a token was ever committed to GitHub, revoke it immediately and generate a new one.

See [SECURITY.md](SECURITY.md) for more details.

