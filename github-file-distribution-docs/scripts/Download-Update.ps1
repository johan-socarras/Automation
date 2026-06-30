# ==========================================
# CONFIGURATION
# ==========================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DownloadUrl   = "https://raw.githubusercontent.com/jsocarras96/Ishida-Updates/main/PLU_Update.txt"
$FileName      = "PLU_Update.txt"

$Destination   = "$env:USERPROFILE\Desktop\$FileName"
$TempFile      = "$env:TEMP\$FileName"

# Unique Store / PC ID
$SiteID        = "LMHOU90"

# GitHub Configuration
$GitHubToken   = "github_pat_ *************************************** " (Token was erased for security reasons)
$RepoOwner     = "jsocarras96"
$RepoName      = "Ishida-Updates"
$Branch        = "main"

# Pending report queue
$PendingQueue  = "$env:ProgramData\IshidaPendingReports.json"

# Current Date Folder
$CurrentDate   = (Get-Date).ToString("yyyy-MM-dd")

# ==========================================
# FUNCTION: SAVE PENDING REPORT
# ==========================================

function Save-PendingReport {
    param (
        [string]$Status
    )

    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $Report = @{
        SiteID    = $SiteID
        Status    = $Status
        Timestamp = $Timestamp
    }

    $Queue = @()

    if (Test-Path $PendingQueue) {
        $Queue = Get-Content $PendingQueue | ConvertFrom-Json
    }

    $Queue += $Report

    $Queue | ConvertTo-Json | Set-Content $PendingQueue
}

# ==========================================
# FUNCTION: SEND REPORT TO GITHUB
# ==========================================

function Send-Report {
    param (
        [string]$Status
    )

    try {

        $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        # TXT content
        $TextContent = @"
SiteID: $SiteID
Status: $Status
Timestamp: $Timestamp
"@

        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($TextContent)
        $Base64Content = [Convert]::ToBase64String($Bytes)

        # Daily folder structure
        $Uri = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/Log/$CurrentDate/$SiteID.txt"

        $Headers = @{
            Authorization = "token $GitHubToken"
            Accept        = "application/vnd.github.v3+json"
        }

        $Sha = $null

        # Check if today's file already exists
        try {

            $ExistingFile = Invoke-RestMethod `
                -Uri $Uri `
                -Headers $Headers `
                -Method Get `
                -ErrorAction Stop

            $Sha = $ExistingFile.sha
        }
        catch {
        }

        $Body = @{
            message = "Daily report from $SiteID"
            content = $Base64Content
            branch  = $Branch
        }

        # Overwrite only if file already exists today
        if ($Sha) {
            $Body.sha = $Sha
        }

        $JsonBody = $Body | ConvertTo-Json

        Invoke-RestMethod `
            -Uri $Uri `
            -Headers $Headers `
            -Method Put `
            -Body $JsonBody `
            -ContentType "application/json" `
            -ErrorAction Stop

        Write-Host "Report sent successfully." -ForegroundColor Green

        return $true
    }
    catch {

        Write-Warning "Unable to send report. Saved locally."

        Save-PendingReport -Status $Status

        return $false
    }
}

# ==========================================
# FUNCTION: PROCESS PENDING REPORTS
# ==========================================

function Process-PendingReports {

    if (-not (Test-Path $PendingQueue)) {
        return
    }

    try {

        $Reports = Get-Content $PendingQueue | ConvertFrom-Json

        foreach ($Report in $Reports) {

            $Result = Send-Report -Status $Report.Status

            if (-not $Result) {
                return
            }
        }

        Remove-Item $PendingQueue -Force

        Write-Host "Pending reports processed." -ForegroundColor Cyan
    }
    catch {
    }
}

# ==========================================
# PROCESS OLD PENDING REPORTS FIRST
# ==========================================

Process-PendingReports

# ==========================================
# DOWNLOAD FILE
# ==========================================

try {

    Invoke-WebRequest `
        -Uri $DownloadUrl `
        -OutFile $TempFile `
        -UseBasicParsing `
        -ErrorAction Stop
}
catch {

    # CASE 4
    # File does not exist in GitHub
    if ($_.Exception.Response.StatusCode.value__ -eq 404) {

        Write-Host "Remote file does not exist. No action taken." -ForegroundColor Yellow
        pause
        exit
    }

    # CASE 3
    # Internet or download failure
    Write-Warning "Download failed."

    Save-PendingReport -Status "Download Failed"

    pause
    exit
}

# ==========================================
# CHECK LOCAL FILE
# ==========================================

if (Test-Path $Destination) {

    $LocalHash = (Get-FileHash $Destination -Algorithm SHA256).Hash
    $RemoteHash = (Get-FileHash $TempFile -Algorithm SHA256).Hash

    # CASE 2
    if ($LocalHash -eq $RemoteHash) {

        Write-Host "File already up to date." -ForegroundColor Yellow

        Remove-Item $TempFile -Force

        $null = Send-Report -Status "File Already Updated"

        pause
        exit
    }
}

# ==========================================
# CASE 1
# UPDATE FILE
# ==========================================

try {

    Move-Item `
        -Path $TempFile `
        -Destination $Destination `
        -Force

    Write-Host "File updated successfully." -ForegroundColor Cyan

    $null = Send-Report -Status "File Updated Successfully"
}
catch {

    Write-Warning "Unable to update local file."

    Save-PendingReport -Status "Local File Update Failed"
}

pause
```
