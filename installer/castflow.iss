#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif

#define BuildDir SourcePath + "..\build\windows\x64\runner\Release"
#define ReleaseDir SourcePath + "..\dist\release"

[Setup]
AppId={{D815D2CC-3A6B-4EC3-8E8E-D29CEEA4D789}
AppName=CastFlow
AppVersion={#AppVersion}
AppPublisher=Elfred
DefaultDirName={autopf}\CastFlow
DefaultGroupName=CastFlow
DisableProgramGroupPage=yes
OutputDir={#ReleaseDir}
OutputBaseFilename=CastFlow-Setup-{#AppVersion}
SetupIconFile={#SourcePath}..\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\castflow.exe

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CastFlow"; Filename: "{app}\castflow.exe"
Name: "{autodesktop}\CastFlow"; Filename: "{app}\castflow.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Créer un raccourci sur le bureau"; GroupDescription: "Raccourcis supplémentaires :"

[Run]
Filename: "{app}\castflow.exe"; Description: "Lancer CastFlow"; Flags: nowait postinstall skipifsilent
