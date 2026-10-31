#define AppName "KOCR"
#define AppVersion GetEnv("VERSION")
#define Target GetEnv("TARGET")
#define Arch GetEnv("ARCH")
#define StageDir "..\..\dist\installer"

[Setup]
AppId={{8F2E4F0E-6D63-4F32-A7C4-0B9E7A3C1D52}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=KercyDing
DefaultDirName={autopf}\KOCR
DefaultGroupName=KOCR
OutputDir=..\..\dist
OutputBaseFilename=kocr-gui-{#AppVersion}-{#Target}-setup
SetupIconFile=..\..\kocr-gui\assets\icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#Arch}
ArchitecturesInstallIn64BitMode={#Arch}
UninstallDisplayIcon={app}\kocr-gui.exe
PrivilegesRequired=admin

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\KOCR"; Filename: "{app}\kocr-gui.exe"
Name: "{group}\Uninstall KOCR"; Filename: "{uninstallexe}"
Name: "{autodesktop}\KOCR"; Filename: "{app}\kocr-gui.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kocr-gui.exe"; Description: "Launch KOCR"; Flags: nowait postinstall skipifsilent
