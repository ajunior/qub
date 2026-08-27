; installer.iss — Inno Setup script for qub.
; Tokens __VERSION__, __STAGE__ and __ICON__ are substituted by deploy.ps1.
#define AppName    "qub"
#define AppVersion "__VERSION__"
#define AppPublisher "ajunior"
#define AppExeName "qub.exe"
#define StageDir   "__STAGE__"
; Absolute, because deploy.ps1 compiles this script from the temp directory and
; a relative path would be resolved against that.
#define IconFile   "__ICON__"

[Setup]
AppId={{F6A1B2C3-D4E5-4F60-A7B8-C9D0E1F2A3B4}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputBaseFilename=qub-{#AppVersion}-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; ── Register qub:// URI scheme ────────────────────────────────────────────────
[Registry]
Root: HKCU; Subkey: "Software\Classes\qub";                          ValueType: string;  ValueData: "URL:qub Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\qub";                          ValueType: string;  ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\qub\shell\open\command";       ValueType: string;  ValueData: """{app}\{#AppExeName}"" ""%1"""

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
