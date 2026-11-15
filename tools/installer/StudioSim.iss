; StudioSim's Windows installer (Inno Setup 6), made by tools/package.sh from the app tools/export.sh made:
;   ISCC /DAppVersion=0.1.0 /DSourceDir=...\dist\Windows /DOutputDir=...\dist /DIconFile=...\game\icon.ico StudioSim.iss
; It installs for the user alone, in their own programs folder, so it asks for no administrator's rights; and it needs
; nothing else installed first (Microsoft's C++ runtime is built into StudioSim's own DLL, and Steam Audio's carries
; its own). Rooms, templates and presets are the user's (Music\StudioSim): uninstalling leaves them.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F0B8E3C-5A41-4E2B-9C7D-2B1F4A8E6D53}
AppName=StudioSim
AppVersion={#AppVersion}
AppVerName=StudioSim {#AppVersion}
AppPublisher=Andrew Angus
AppPublisherURL=https://github.com/AngusA1210/StudioSim
AppSupportURL=https://github.com/AngusA1210/StudioSim/issues
AppUpdatesURL=https://github.com/AngusA1210/StudioSim/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\StudioSim
DefaultGroupName=StudioSim
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=StudioSim-Windows-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\StudioSim.exe
UninstallDisplayName=StudioSim
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Put a StudioSim shortcut on the desktop"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceDir}\StudioSim.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\StudioSim"; Filename: "{app}\StudioSim.exe"
Name: "{autodesktop}\StudioSim"; Filename: "{app}\StudioSim.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\StudioSim.exe"; Description: "Open StudioSim"; Flags: nowait postinstall skipifsilent
