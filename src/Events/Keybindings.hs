module Events.Keybindings
  ( defaultBindings
  , lookupKeybinding
  , getFirstDefaultBinding

  , mkKb
  , staticKb
  , mkKeybindings

  , handleKeyboardEvent

  -- Re-exports:
  , Keybinding (..)
  , KeyEvent (..)
  , KeyConfig
  , allEvents
  , parseBinding
  , keyEventName
  , keyEventFromName

  , ensureKeybindingConsistency
  )
where

import           Prelude ()
import           Prelude.MH

import qualified Data.Text as T
import qualified Data.Map.Strict as M
import qualified Graphics.Vty as Vty

import           Types
import           Types.KeyEvents


-- * Keybindings

-- | A 'Keybinding' represents a keybinding along with its
--   implementation
data Keybinding =
    KB { kbDescription :: Text
       , kbEvent :: Maybe Vty.Event
       , kbAction :: MH ()
       , kbBindingInfo :: Maybe KeyEvent
       }

-- | Find a keybinding that matches a Vty Event
lookupKeybinding :: Vty.Event -> [Keybinding] -> Maybe Keybinding
lookupKeybinding e kbs = listToMaybe $ filter ((== Just e) . kbEvent) kbs

-- | Handle a keyboard event by matching it against a list of bindings
-- and invoking the matching binding's handler. If no match can be
-- found, invoke a fallback action instead. Return True if the key event
-- was handled with a matching binding; False if not (the fallback
-- case).
handleKeyboardEvent :: (KeyConfig -> [Keybinding])
                    -- ^ The function to build a keybinding list from a
                    -- key configuration.
                    -> (Vty.Event -> MH ())
                    -- ^ The fallback action to invoke if no matching
                    -- binding can be found.
                    -> Vty.Event
                    -- ^ The event to handle.
                    -> MH Bool
handleKeyboardEvent keyList fallthrough e = do
  conf <- use (csResources.crConfiguration)
  let keyMap = keyList (configUserKeys conf)
  case lookupKeybinding e keyMap of
    Just kb -> kbAction kb >> return True
    Nothing -> fallthrough e >> return False

mkKb :: KeyEvent -> Text -> MH () -> KeyConfig -> [Keybinding]
mkKb ev msg action conf =
  if null allKeys
  then [ KB msg Nothing action (Just ev) ]
  else [ KB msg (Just $ bindingToEvent key) action (Just ev) | key <- allKeys ]
  where allKeys | Just (BindingList ks) <- M.lookup ev conf = ks
                | Just Unbound <- M.lookup ev conf = []
                | otherwise = defaultBindings ev

staticKb :: Text -> Vty.Event -> MH () -> KeyConfig -> [Keybinding]
staticKb msg event action _ = [KB msg (Just event) action Nothing]

mkKeybindings :: [KeyConfig -> [Keybinding]] -> KeyConfig -> [Keybinding]
mkKeybindings ks conf = concat [ k conf | k <- ks ]

bindingToEvent :: Binding -> Vty.Event
bindingToEvent binding =
  Vty.EvKey (kbKey binding) (kbMods binding)

getFirstDefaultBinding :: KeyEvent -> Binding
getFirstDefaultBinding ev =
    case defaultBindings ev of
        [] -> error $ "BUG: event " <> show ev <> " has no default bindings!"
        (b:_) -> b

defaultBindings :: KeyEvent -> [Binding]
defaultBindings ev =
  let meta binding = binding { kbMods = Vty.MMeta : kbMods binding }
      ctrl binding = binding { kbMods = Vty.MCtrl : kbMods binding }
      kb k = Binding { kbMods = [], kbKey = k }
      key c = Binding { kbMods = [], kbKey = Vty.KChar c }
      fn n = Binding { kbMods = [], kbKey = Vty.KFun n }
  in case ev of
        VtyRefreshEvent               -> [ ctrl (key 'l') ]
        ShowHelpEvent                 -> [ fn 1 ]
        EnterSelectModeEvent          -> [ ctrl (key 's') ]
        ReplyRecentEvent              -> [ ctrl (key 'r') ]
        ToggleMessagePreviewEvent     -> [ meta (key 'p') ]
        InvokeEditorEvent             -> [ meta (key 'k') ]
        EnterFastSelectModeEvent      -> [ ctrl (key 'g') ]
        QuitEvent                     -> [ ctrl (key 'q') ]
        NextChannelEvent              -> [ ctrl (key 'n') ]
        PrevChannelEvent              -> [ ctrl (key 'p') ]
        NextChannelEventAlternate     -> [ kb Vty.KDown ]
        PrevChannelEventAlternate     -> [ kb Vty.KUp ]
        NextUnreadChannelEvent        -> [ meta (key 'a') ]
        ShowAttachmentListEvent       -> [ ctrl (key 'x') ]
        NextUnreadUserOrChannelEvent  -> [ ]
        LastChannelEvent              -> [ meta (key 's') ]
        EnterOpenURLModeEvent         -> [ ctrl (key 'o') ]
        ClearUnreadEvent              -> [ meta (key 'l') ]
        ToggleMultiLineEvent          -> [ meta (key 'e') ]
        EnterFlaggedPostsEvent        -> [ meta (key '8') ]
        ToggleChannelListVisibleEvent -> [ fn 2 ]
        SelectNextTabEvent            -> [ key '\t' ]
        SelectPreviousTabEvent        -> [ kb Vty.KBackTab ]
        LoadMoreEvent                 -> [ ctrl (key 'b') ]
        ScrollUpEvent                 -> [ kb Vty.KUp ]
        ScrollDownEvent               -> [ kb Vty.KDown ]
        ScrollLeftEvent               -> [ kb Vty.KLeft ]
        ScrollRightEvent              -> [ kb Vty.KRight ]
        PageUpEvent                   -> [ kb Vty.KPageUp ]
        PageDownEvent                 -> [ kb Vty.KPageDown ]
        ScrollTopEvent                -> [ kb Vty.KHome ]
        ScrollBottomEvent             -> [ kb Vty.KEnd ]
        SelectUpEvent                 -> [ key 'k', kb Vty.KUp ]
        SelectDownEvent               -> [ key 'j', kb Vty.KDown ]
        ActivateListItemEvent         -> [ kb Vty.KEnter ]
        SearchSelectUpEvent           -> [ ctrl (key 'p'), kb Vty.KUp ]
        SearchSelectDownEvent         -> [ ctrl (key 'n'), kb Vty.KDown ]
        ViewMessageEvent              -> [ key 'v' ]
        FillGapEvent                  -> [ kb Vty.KEnter ]
        FlagMessageEvent              -> [ key 'f' ]
        PinMessageEvent               -> [ key 'p' ]
        YankMessageEvent              -> [ key 'y' ]
        YankWholeMessageEvent         -> [ key 'Y' ]
        DeleteMessageEvent            -> [ key 'd' ]
        EditMessageEvent              -> [ key 'e' ]
        ReplyMessageEvent             -> [ key 'r' ]
        ReactToMessageEvent           -> [ key 'a' ]
        OpenMessageURLEvent           -> [ key 'o' ]
        AttachmentListAddEvent        -> [ key 'a' ]
        AttachmentListDeleteEvent     -> [ key 'd' ]
        AttachmentOpenEvent           -> [ key 'o' ]
        CancelEvent                   -> [ kb Vty.KEsc, ctrl (key 'c') ]
        EditorBolEvent                -> [ ctrl (key 'a') ]
        EditorEolEvent                -> [ ctrl (key 'e') ]
        EditorTransposeCharsEvent     -> [ ctrl (key 't') ]
        EditorDeleteCharacter         -> [ ctrl (key 'd') ]
        EditorKillToBolEvent          -> [ ctrl (key 'u') ]
        EditorKillToEolEvent          -> [ ctrl (key 'k') ]
        EditorPrevCharEvent           -> [ ctrl (key 'b') ]
        EditorNextCharEvent           -> [ ctrl (key 'f') ]
        EditorPrevWordEvent           -> [ meta (key 'b') ]
        EditorNextWordEvent           -> [ meta (key 'f') ]
        EditorDeleteNextWordEvent     -> [ meta (key 'd') ]
        EditorDeletePrevWordEvent     -> [ ctrl (key 'w'), meta (kb Vty.KBS) ]
        EditorHomeEvent               -> [ kb Vty.KHome ]
        EditorEndEvent                -> [ kb Vty.KEnd ]
        EditorYankEvent               -> [ ctrl (key 'y') ]

-- | Given a configuration, we want to check it for internal consistency
-- (i.e. that a given keybinding isn't associated with multiple events
-- which both need to get generated in the same UI mode) and also for
-- basic usability (i.e. we shouldn't be binding events which can appear
-- in the main UI to a key like @e@, which would prevent us from being
-- able to type messages containing an @e@ in them!
ensureKeybindingConsistency :: KeyConfig -> [(String, KeyConfig -> [Keybinding])] -> Either String ()
ensureKeybindingConsistency kc modeMaps = mapM_ checkGroup allBindings
  where
    -- This is a list of lists, grouped by keybinding, of all the
    -- keybinding/event associations that are going to be used with the
    -- provided key configuration.
    allBindings = groupWith fst $ concat
      [ case M.lookup ev kc of
          Nothing -> zip (defaultBindings ev) (repeat (False, ev))
          Just (BindingList bs) -> zip bs (repeat (True, ev))
          Just Unbound -> []
      | ev <- allEvents
      ]

    -- The invariant here is that each call to checkGroup is made with a
    -- list where the first element of every list is the same binding.
    -- The Bool value in these is True if the event was associated with
    -- the binding by the user, and False if it's a Matterhorn default.
    checkGroup :: [(Binding, (Bool, KeyEvent))] -> Either String ()
    checkGroup [] = error "[ensureKeybindingConsistency: unreachable]"
    checkGroup evs@((b, _):_) = do

      -- We find out which modes an event can be used in and then invert
      -- the map, so this is a map from mode to the events contains
      -- which are bound by the binding included above.
      let modesFor :: M.Map String [(Bool, KeyEvent)]
          modesFor = M.unionsWith (++)
            [ M.fromList [ (m, [(i, ev)]) | m <- modeMap ev ]
            | (_, (i, ev)) <- evs
            ]

      -- If there is ever a situation where the same key is bound to two
      -- events which can appear in the same mode, then we want to throw
      -- an error, and also be informative about why. It is still okay
      -- to bind the same key to two events, so long as those events
      -- never appear in the same UI mode.
      forM_ (M.assocs modesFor) $ \ (_, vs) ->
         when (length vs > 1) $
           Left $ concat $
             "Multiple overlapping events bound to `" :
             T.unpack (ppBinding b) :
             "`:\n" :
             concat [ [ " - `"
                      , T.unpack (keyEventName ev)
                      , "` "
                      , if isFromUser
                          then "(via user override)"
                          else "(matterhorn default)"
                      , "\n"
                      ]
                    | (isFromUser, ev) <- vs
                    ]

      -- Check for overlap a set of built-in keybindings when we're in a
      -- mode where the user is typing. (These are perfectly fine when
      -- we're in other modes.)
      when ("main" `M.member` modesFor && isBareBinding b) $ do
        Left $ concat $
          [ "The keybinding `"
          , T.unpack (ppBinding b)
          , "` is bound to the "
          , case map (ppEvent . snd . snd) evs of
              [] -> error "unreachable"
              [e] -> "event " ++ e
              es  -> "events " ++ intercalate " and " es
          , "\n"
          , "This is probably not what you want, as it will interfere "
          , "with the ability to write messages!\n"
          ]

    -- Events get some nice formatting!
    ppEvent ev = "`" ++ T.unpack (keyEventName ev) ++ "`"

    -- This check should get more nuanced, but as a first approximation,
    -- we shouldn't bind to any bare character key in the main mode.
    isBareBinding (Binding [] (Vty.KChar {})) = True
    isBareBinding _ = False

    -- We generate the which-events-are-valid-in-which-modes map from
    -- our actual keybinding set, so this should never get out of date.
    modeMap ev =
      let bindingHasEvent (KB _ _ _ (Just ev')) = ev == ev'
          bindingHasEvent _ = False
      in [ mode
         | (mode, mkBindings) <- modeMaps
         , any bindingHasEvent (mkBindings kc)
         ]
