; Inno Setup script for the Windows installer.
;   iscc /DAppVersion=0.1.0 /DSourceDir=<release dir> /DOutputDir=<dist> packaging\windows\kilonova.iss
; SourceDir is app\build\windows\x64\runner\Release after `flutter build windows --release`.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F7B2A1E-3C84-4D5A-9E0F-1B2C3D4E5F60}
AppName=Kilonova
AppVersion={#AppVersion}
AppPublisher=Dhiva Labs
AppPublisherURL=https://github.com/Dhiva-Labs/kilonova
DefaultDirName={autopf}\Kilonova
DefaultGroupName=Kilonova
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=kilonova-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kilonova.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Kilonova"; Filename: "{app}\kilonova.exe"
Name: "{autodesktop}\Kilonova"; Filename: "{app}\kilonova.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kilonova.exe"; Description: "{cm:LaunchProgram,Kilonova}"; Flags: nowait postinstall skipifsilent
