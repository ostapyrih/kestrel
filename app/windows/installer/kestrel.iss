; Inno Setup script for the Kestrel Windows installer (per-user, no admin rights).
; Build: ISCC /DAppVersion=0.6.0 /DSourceDir=<Flutter Release dir> /DOutDir=<dir> kestrel.iss
; The in-app updater runs the installer directly with /VERYSILENT /SUPPRESSMSGBOXES
; /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /LOG=<file>.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutDir
  #define OutDir "..\..\..\dist"
#endif

[Setup]
; Never change AppId: it identifies the installation for upgrades and uninstall.
AppId={{B3F1A6C2-7D4E-4A58-9E21-5C0D8F7A1B34}
AppName=Kestrel
AppVersion={#AppVersion}
AppPublisher=ostapyrih
AppPublisherURL=https://github.com/ostapyrih/kestrel
DefaultDirName={localappdata}\Programs\Kestrel
DefaultGroupName=Kestrel
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename=kestrel-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kestrel.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Close a running Kestrel so its files can be replaced (the in-app updater
; starts this installer and exits); the silent [Run] entry below relaunches it.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kestrel"; Filename: "{app}\kestrel.exe"

[Run]
Filename: "{app}\kestrel.exe"; Description: "{cm:LaunchProgram,Kestrel}"; Flags: nowait postinstall skipifsilent
; Silent (in-app update) installs relaunch the app as the original user.
Filename: "{app}\kestrel.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent
