#define AppName "kocr"
#define AppVersion GetEnv("VERSION")
#define InnoArch GetEnv("ARCH")
#define OutArch GetEnv("OUT_ARCH")
#define StageDir "..\..\zig-out\stage\windows"

[Setup]
AppId={{6F0B3B7E-2F5A-4C8E-9E1B-3C6D5A7F9D21}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=KercyDing
AppPublisherURL=https://github.com/KercyDing/kocr
DefaultDirName={autopf}\kocr
DefaultGroupName=kocr
DisableProgramGroupPage=yes
OutputDir=..\..\zig-out\bundle\windows
OutputBaseFilename=kocr-{#AppVersion}-windows-{#OutArch}-setup
SetupIconFile=..\..\src\gui\icons\kocr.ico
UninstallDisplayIcon={app}\kocr-gui.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#InnoArch}
ArchitecturesInstallIn64BitMode={#InnoArch}
PrivilegesRequired=admin

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#StageDir}\kocr-gui.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\kocr"; Filename: "{app}\kocr-gui.exe"
Name: "{group}\Uninstall kocr"; Filename: "{uninstallexe}"
Name: "{autodesktop}\kocr"; Filename: "{app}\kocr-gui.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kocr-gui.exe"; Description: "Launch kocr"; Flags: nowait postinstall skipifsilent
