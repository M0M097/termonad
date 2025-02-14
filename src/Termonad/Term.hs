{-# LANGUAGE CPP #-}

module Termonad.Term where

import Termonad.Prelude

import Control.Lens ((^.), (.~), set, to)
import Data.Colour.SRGB (Colour, RGB(RGB), toSRGB)
import Data.FocusList (appendFL, deleteFL, getFocusItemFL)
import GI.Gdk
  ( EventButton
  , EventKey
  , RGBA
  , getEventButtonButton
  , newZeroRGBA
  , setRGBABlue
  , setRGBAGreen
  , setRGBARed
  )
import GI.Gdk.Constants (pattern BUTTON_SECONDARY)
import GI.Gio
  ( Cancellable
  , menuAppend
  , menuNew
  )
import GI.GLib
  ( SpawnFlags(SpawnFlagsDefault)
  )
import GI.Gtk
  ( Adjustment
  , Align(AlignFill)
  , ApplicationWindow
  , Box
  , Button
  , IconSize(IconSizeMenu)
  , Label
  , Notebook
  , Orientation(OrientationHorizontal)
  , PolicyType(PolicyTypeAlways, PolicyTypeAutomatic, PolicyTypeNever)
  , ReliefStyle(ReliefStyleNone)
  , ResponseType(ResponseTypeNo, ResponseTypeYes)
  , ScrolledWindow
  , applicationGetActiveWindow
  , boxNew
  , buttonNewFromIconName
  , buttonSetRelief
  , containerAdd
  , dialogAddButton
  , dialogGetContentArea
  , dialogNew
  , dialogRun
  , labelNew
  , labelSetEllipsize
  , labelSetLabel
  , labelSetMaxWidthChars
  , menuAttachToWidget
  , menuNewFromModel
  , menuPopupAtPointer
  , notebookAppendPage
  , notebookDetachTab
  , notebookGetNPages
  , notebookPageNum
  , notebookSetCurrentPage
  , notebookSetShowTabs
  , notebookSetTabReorderable
  , onButtonClicked
  , onWidgetButtonPressEvent
  , onWidgetKeyPressEvent
  , scrolledWindowNew
  , scrolledWindowSetPolicy
  , setWidgetMargin
  , widgetDestroy
  , widgetGrabFocus
  , widgetSetCanFocus
  , widgetSetHalign
  , widgetSetHexpand
  , widgetShow
  , windowSetFocus
  , windowSetTransientFor
  )
import GI.Pango (EllipsizeMode(EllipsizeModeMiddle), FontDescription)
import GI.Vte
  ( PtyFlags(PtyFlagsDefault)
  , Terminal
  , onTerminalChildExited
  , onTerminalWindowTitleChanged
  , terminalGetWindowTitle
  , terminalNew
  , terminalSetCursorBlinkMode
  , terminalSetFont
  , terminalSetScrollbackLines
  , terminalSpawnSync
  , terminalSetWordCharExceptions
  )
import System.Directory (getSymbolicLinkTarget)
import System.Environment (lookupEnv)

import Termonad.Lenses
  ( lensConfirmExit
  , lensOptions
  , lensShowScrollbar
  , lensShowTabBar
  , lensTMNotebookTabLabel
  , lensTMNotebookTabTerm
  , lensTMNotebookTabTermContainer
  , lensTMNotebookTabs
  , lensTMStateApp
  , lensTMStateConfig
  , lensTMStateNotebook
  , lensTerm
  )
import Termonad.Types
  ( ConfigHooks(createTermHook)
  , ConfigOptions(scrollbackLen, wordCharExceptions, cursorBlinkMode)
  , ShowScrollbar(..)
  , ShowTabBar(..)
  , TMConfig(hooks, options)
  , TMNotebook
  , TMNotebookTab
  , TMState
  , TMState'(TMState, tmStateAppWin, tmStateConfig, tmStateFontDesc, tmStateNotebook)
  , TMTerm
  , assertInvariantTMState
  , createTMNotebookTab
  , newTMTerm
  , pid
  , tmNotebook
  , tmNotebookTabTerm
  , tmNotebookTabTermContainer
  , tmNotebookTabs
  )

focusTerm :: Int -> TMState -> IO ()
focusTerm i mvarTMState = do
  note <- tmNotebook . tmStateNotebook <$> readMVar mvarTMState
  notebookSetCurrentPage note (fromIntegral i)

altNumSwitchTerm :: Int -> TMState -> IO ()
altNumSwitchTerm = focusTerm

termExitFocused :: TMState -> IO ()
termExitFocused mvarTMState = do
  tmState <- readMVar mvarTMState
  let maybeTab =
        tmState ^. lensTMStateNotebook . lensTMNotebookTabs . to getFocusItemFL
  case maybeTab of
    Nothing -> pure ()
    Just tab -> termClose tab mvarTMState

termClose :: TMNotebookTab -> TMState -> IO ()
termClose tab mvarTMState = do
  tmState <- readMVar mvarTMState
  let confirm = tmState ^. lensTMStateConfig . lensOptions . lensConfirmExit
      close = if confirm then termExitWithConfirmation else termExit
  close tab mvarTMState

termExitWithConfirmation :: TMNotebookTab -> TMState -> IO ()
termExitWithConfirmation tab mvarTMState = do
  tmState <- readMVar mvarTMState
  let app = tmState ^. lensTMStateApp
  win <- applicationGetActiveWindow app
  dialog <- dialogNew
  box <- dialogGetContentArea dialog
  label <- labelNew (Just "Close tab?")
  containerAdd box label
  widgetShow label
  setWidgetMargin label 10
  void $
    dialogAddButton
      dialog
      "No, do NOT close tab"
      (fromIntegral (fromEnum ResponseTypeNo))
  void $
    dialogAddButton
      dialog
      "Yes, close tab"
      (fromIntegral (fromEnum ResponseTypeYes))
  windowSetTransientFor dialog win
  res <- dialogRun dialog
  widgetDestroy dialog
  case toEnum (fromIntegral res) of
    ResponseTypeYes -> termExit tab mvarTMState
    _ -> pure ()

termExit :: TMNotebookTab -> TMState -> IO ()
termExit tab mvarTMState = do
  detachTabAction <-
    modifyMVar mvarTMState $ \tmState -> do
      let notebook = tmStateNotebook tmState
          detachTabAction =
            notebookDetachTab
              (tmNotebook notebook)
              (tmNotebookTabTermContainer tab)
      let newTabs = deleteFL tab (tmNotebookTabs notebook)
      let newTMState =
            set (lensTMStateNotebook . lensTMNotebookTabs) newTabs tmState
      pure (newTMState, detachTabAction)
  detachTabAction
  relabelTabs mvarTMState

relabelTabs :: TMState -> IO ()
relabelTabs mvarTMState = do
  TMState{tmStateNotebook} <- readMVar mvarTMState
  let notebook = tmNotebook tmStateNotebook
      tabFocusList = tmNotebookTabs tmStateNotebook
  foldMap (go notebook) tabFocusList
  where
    go :: Notebook -> TMNotebookTab -> IO ()
    go notebook tmNotebookTab = do
      let label = tmNotebookTab ^. lensTMNotebookTabLabel
          scrolledWin = tmNotebookTab ^. lensTMNotebookTabTermContainer
          term' = tmNotebookTab ^. lensTMNotebookTabTerm . lensTerm
      relabelTab notebook label scrolledWin term'

-- | Compute the text for a 'Label' for a GTK Notebook tab.
--
-- >>> computeTabLabel 0 (Just "me@machine:~")
-- "1. me@machine:~"
--
-- >>> computeTabLabel 5 (Just "bash process")
-- "6. bash process"
--
-- >>> computeTabLabel 2 Nothing
-- "3. shell"
computeTabLabel
  :: Int
  -- ^ Tab number.  0 is used for the first tab, 1 for the second, etc.
  -> Maybe Text
  -- ^ A possible title for a tab.  If this is 'Nothing', then the string
  -- @shell@ will be used.
  -> Text
computeTabLabel pageNum maybeTitle =
  let title = fromMaybe "shell" maybeTitle
  in tshow (pageNum + 1) <> ". " <> title

-- | Update the given 'Label' for a GTK Notebook tab.
--
-- The new text for the label is determined by the 'computeTabLabel' function.
relabelTab :: Notebook -> Label -> ScrolledWindow -> Terminal -> IO ()
relabelTab notebook label scrolledWin term' = do
  tabNum <- notebookPageNum notebook scrolledWin
  maybeTitle <- terminalGetWindowTitle term'
  let labelText = computeTabLabel (fromIntegral tabNum) maybeTitle
  labelSetLabel label labelText

showScrollbarToPolicy :: ShowScrollbar -> PolicyType
showScrollbarToPolicy ShowScrollbarNever = PolicyTypeNever
showScrollbarToPolicy ShowScrollbarIfNeeded = PolicyTypeAutomatic
showScrollbarToPolicy ShowScrollbarAlways = PolicyTypeAlways

createScrolledWin :: TMState -> IO ScrolledWindow
createScrolledWin mvarTMState = do
  tmState <- readMVar mvarTMState
  let showScrollbarVal =
        tmState ^. lensTMStateConfig . lensOptions . lensShowScrollbar
      vScrollbarPolicy = showScrollbarToPolicy showScrollbarVal
  scrolledWin <-
    scrolledWindowNew
      (Nothing :: Maybe Adjustment)
      (Nothing :: Maybe Adjustment)
  widgetShow scrolledWin
  scrolledWindowSetPolicy scrolledWin PolicyTypeAutomatic vScrollbarPolicy
  pure scrolledWin

createNotebookTabLabel :: IO (Box, Label, Button)
createNotebookTabLabel = do
  box <- boxNew OrientationHorizontal 5
  label <- labelNew (Just "")
  labelSetEllipsize label EllipsizeModeMiddle
  labelSetMaxWidthChars label 10
  widgetSetHexpand label True
  widgetSetHalign label AlignFill
  button <-
    buttonNewFromIconName
      (Just "window-close")
      (fromIntegral (fromEnum IconSizeMenu))
  buttonSetRelief button ReliefStyleNone
  containerAdd box label
  containerAdd box button
  widgetSetCanFocus button False
  widgetSetCanFocus label False
  widgetSetCanFocus box False
  widgetShow box
  widgetShow label
  widgetShow button
  pure (box, label, button)

setShowTabs :: TMConfig -> Notebook -> IO ()
setShowTabs tmConfig note = do
  npages <- notebookGetNPages note
  let shouldShowTabs =
        case tmConfig ^. lensOptions . lensShowTabBar of
          ShowTabBarIfNeeded -> npages > 1
          ShowTabBarAlways   -> True
          ShowTabBarNever    -> False
  notebookSetShowTabs note shouldShowTabs

toRGBA :: Colour Double -> IO RGBA
toRGBA colour = do
  let RGB red green blue = toSRGB colour
  rgba <- newZeroRGBA
  setRGBARed rgba red
  setRGBAGreen rgba green
  setRGBABlue rgba blue
  pure rgba

-- | TODO: This should probably be implemented in an external package,
-- since it is a generally useful utility.
--
-- It should also be implemented for windows and osx.
cwdOfPid :: Int -> IO (Maybe Text)
cwdOfPid pd = do
#ifdef mingw32_HOST_OS
  pure Nothing
#else
#ifdef darwin_HOST_OS
  pure Nothing
#else
  let pidPath = "/proc" </> show pd </> "cwd"
  eitherLinkTarget <- try $ getSymbolicLinkTarget pidPath
  case eitherLinkTarget of
    Left (_ :: IOException) -> pure Nothing
    Right linkTarget -> pure $ Just $ pack linkTarget
#endif
#endif

-- | Get the current working directory from the shell in the focused tab of a
-- notebook.
--
-- Returns 'Nothing' if there is no focused tab of the notebook, or the
-- current working directory could not be detected for the shell.
getCWDFromFocusedTab :: TMNotebook -> IO (Maybe Text)
getCWDFromFocusedTab currNote = do
  let maybeFocusedTab = getFocusItemFL (tmNotebookTabs currNote)
  case maybeFocusedTab of
    Nothing -> pure Nothing
    Just focusedNotebookTab -> do
      let shellPid = pid (tmNotebookTabTerm focusedNotebookTab)
      cwdOfPid shellPid

-- | Create the VTE 'Terminal', set the fonts and options
createAndInitVteTerm :: FontDescription -> ConfigOptions -> IO Terminal
createAndInitVteTerm tmStateFontDesc curOpts = do
  vteTerm <- terminalNew
  terminalSetFont vteTerm (Just tmStateFontDesc)
  terminalSetWordCharExceptions vteTerm $ wordCharExceptions curOpts
  terminalSetScrollbackLines vteTerm (fromIntegral (scrollbackLen curOpts))
  terminalSetCursorBlinkMode vteTerm (cursorBlinkMode curOpts)
  widgetShow vteTerm
  pure vteTerm

-- | Starts a shell in a terminal and return a new TMTerm
launchShell
  :: Terminal
  -- ^ GTK 'Terminal' to spawn the shell in.
  -> Maybe Text
  -- ^ An optional path to the current working directory to start the
  -- shell in.  If 'Nothing', use the current working directory of the
  -- termonad process.
  -> IO Int
launchShell vteTerm maybeCurrDir = do
  -- Should probably use GI.Vte.Functions.getUserShell, but contrary to its
  -- documentation it raises an exception rather wrap in Maybe.
  mShell <- lookupEnv "SHELL"
  let argv = maybe ["/usr/bin/env", "bash"] pure mShell
  -- Launch the shell
  shellPid <-
    terminalSpawnSync
      vteTerm
      [PtyFlagsDefault]
      maybeCurrDir
      argv
      Nothing
      ([SpawnFlagsDefault] :: [SpawnFlags])
      Nothing
      (Nothing :: Maybe Cancellable)
  pure (fromIntegral shellPid)

-- | Add a page to the notebook and switch to it.
addPage
  :: TMState
  -> TMNotebookTab
  -> Box
  -- ^ The GTK Object holding the label we want to show for the tab of the
  -- newly created page of the notebook.
  -> IO ()
addPage mvarTMState notebookTab tabLabelBox = do
  -- Append a new notebook page and update the TMState to reflect this.
  (note, pageIndex) <- modifyMVar mvarTMState appendNotebookPage

  -- Switch the current Notebook page to the the newly added page.
  notebookSetCurrentPage note pageIndex
  where
    appendNotebookPage :: TMState' -> IO (TMState', (Notebook, Int32))
    appendNotebookPage tmState = do
      let notebook = tmStateNotebook tmState
          note = tmNotebook notebook
          tabs = tmNotebookTabs notebook
          scrolledWin = tmNotebookTabTermContainer notebookTab
      pageIndex <- notebookAppendPage note scrolledWin (Just tabLabelBox)
      notebookSetTabReorderable note scrolledWin True
      setShowTabs (tmState ^. lensTMStateConfig) note
      let newTabs = appendFL tabs notebookTab
          newTMState =
            tmState & lensTMStateNotebook . lensTMNotebookTabs .~ newTabs
      pure (newTMState, (note, pageIndex))

-- | Set the keyboard focus on a vte terminal
setFocusOn :: ApplicationWindow -> Terminal -> IO()
setFocusOn tmStateAppWin vteTerm = do
  widgetGrabFocus vteTerm
  windowSetFocus tmStateAppWin (Just vteTerm)

-- | Create a new 'TMTerm', setting it up and adding it to the GTKNotebook.
createTerm
  :: (TMState -> EventKey -> IO Bool)
  -- ^ Funtion for handling key presses on the terminal.
  -> TMState
  -> IO TMTerm
createTerm handleKeyPress mvarTMState = do
  -- Check preconditions
  assertInvariantTMState mvarTMState

  -- Read needed data in TMVar
  TMState{tmStateAppWin, tmStateFontDesc, tmStateConfig, tmStateNotebook=currNote} <-
    readMVar mvarTMState

  -- Create a new terminal and launch a shell in it
  vteTerm <- createAndInitVteTerm tmStateFontDesc (options tmStateConfig)
  maybeCurrDir <- getCWDFromFocusedTab currNote
  termShellPid <- launchShell vteTerm maybeCurrDir
  tmTerm <- newTMTerm vteTerm termShellPid

  -- Create the container add the VTE term in it
  scrolledWin <- createScrolledWin mvarTMState
  containerAdd scrolledWin vteTerm

  -- Create the GTK widget for the Notebook tab
  (tabLabelBox, tabLabel, tabCloseButton) <- createNotebookTabLabel

  -- Create notebook state
  let notebookTab = createTMNotebookTab tabLabel scrolledWin tmTerm

  -- Add the new notebooktab to the notebook.
  addPage mvarTMState notebookTab tabLabelBox

  -- Setup the initial label for the notebook tab.  This needs to happen
  -- after we add the new page to the notebook, so that the page can get labelled
  -- appropriately.
  relabelTab (tmNotebook currNote) tabLabel scrolledWin vteTerm

  -- Connect callbacks
  void $ onButtonClicked tabCloseButton $ termClose notebookTab mvarTMState
  void $ onTerminalWindowTitleChanged vteTerm $ do
    TMState{tmStateNotebook} <- readMVar mvarTMState
    let notebook = tmNotebook tmStateNotebook
    relabelTab notebook tabLabel scrolledWin vteTerm
  void $ onWidgetKeyPressEvent vteTerm $ handleKeyPress mvarTMState
  void $ onWidgetKeyPressEvent scrolledWin $ handleKeyPress mvarTMState
  void $ onWidgetButtonPressEvent vteTerm $ handleMousePress vteTerm
  void $ onTerminalChildExited vteTerm $ \_ -> termExit notebookTab mvarTMState

  -- Put the keyboard focus on the term
  setFocusOn tmStateAppWin vteTerm

  -- Make sure the state is still right
  assertInvariantTMState mvarTMState

  -- Run user-defined hooks for modifying the newly-created VTE Terminal.
  createTermHook (hooks tmStateConfig) mvarTMState vteTerm
  pure tmTerm

-- | Popup the context menu on right click
handleMousePress :: Terminal -> EventButton -> IO Bool
handleMousePress vteTerm event = do
  button <- getEventButtonButton event
  let rightClick = button == fromIntegral BUTTON_SECONDARY
  when rightClick $ do
    menuModel <- menuNew
    menuAppend menuModel (Just "Copy") (Just "app.copy")
    menuAppend menuModel (Just "Paste") (Just "app.paste")
    menuAppend menuModel (Just "Preferences") (Just "app.preferences")
    menu <- menuNewFromModel menuModel
    menuAttachToWidget menu vteTerm Nothing
    menuPopupAtPointer menu Nothing
  pure rightClick
