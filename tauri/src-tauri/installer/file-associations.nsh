!include "${__FILEDIR__}\media-extensions.nsh"

!define PLAYER_CAPABILITIES "Software\BrushLLM\Player\Capabilities"
!define PLAYER_MEDIA_CLASS "BrushLLM.Player.Media"

!macro RegisterPlayerExtension EXT
  WriteRegStr SHCTX "${PLAYER_CAPABILITIES}\FileAssociations" ".${EXT}" "${PLAYER_MEDIA_CLASS}"
  WriteRegStr SHCTX "Software\Classes\.${EXT}\OpenWithProgids" "${PLAYER_MEDIA_CLASS}" ""
!macroend

!macro UnregisterPlayerExtension EXT
  DeleteRegValue SHCTX "Software\Classes\.${EXT}\OpenWithProgids" "${PLAYER_MEDIA_CLASS}"
  DeleteRegKey /ifempty SHCTX "Software\Classes\.${EXT}\OpenWithProgids"
  DeleteRegKey /ifempty SHCTX "Software\Classes\.${EXT}"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr SHCTX "${PLAYER_CAPABILITIES}" "ApplicationName" "${PRODUCTNAME}"
  WriteRegStr SHCTX "${PLAYER_CAPABILITIES}" "ApplicationDescription" "Play video, audio and playlists with mpv."
  WriteRegStr SHCTX "Software\RegisteredApplications" "${PRODUCTNAME}" "${PLAYER_CAPABILITIES}"
  WriteRegStr SHCTX "Software\Classes\${PLAYER_MEDIA_CLASS}" "" "BrushLLM Player media"
  WriteRegStr SHCTX "Software\Classes\${PLAYER_MEDIA_CLASS}\DefaultIcon" "" '"$INSTDIR\${MAINBINARYNAME}.exe",0'
  WriteRegStr SHCTX "Software\Classes\${PLAYER_MEDIA_CLASS}\shell\open\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "%1"'
  !insertmacro ForEachPlayerExtension RegisterPlayerExtension
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  !insertmacro ForEachPlayerExtension UnregisterPlayerExtension
  DeleteRegKey SHCTX "Software\Classes\${PLAYER_MEDIA_CLASS}"
  DeleteRegValue SHCTX "Software\RegisteredApplications" "${PRODUCTNAME}"
  DeleteRegKey SHCTX "${PLAYER_CAPABILITIES}"
  DeleteRegKey /ifempty SHCTX "Software\BrushLLM\Player"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
!macroend
