{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Types
  ( ConnectionStatus(..)
  , HelpTopic(..)
  , MessageSelectState(..)
  , ProgramOutput(..)
  , MHEvent(..)
  , Name(..)
  , ChannelSelectMatch(..)
  , ConnectionInfo(..)
  , Config(..)
  , HelpScreen(..)
  , PasswordSource(..)
  , MatchType(..)
  , EditMode(..)
  , Mode(..)
  , ChannelSelectPattern(..)
  , PostListContents(..)
  , ChannelSelectMap
  , AuthenticationException(..)
  , RequestChan

  , MMNames
  , mkChanNames
  , cnUsers
  , cnToUserId
  , cnToChanId
  , cnChans

  , LinkChoice(LinkChoice)
  , linkUser
  , linkURL
  , linkTime
  , linkName
  , linkFileId

  , ChatState
  , newState
  , csResources
  , csFocus
  , csCurrentChannel
  , csCurrentChannelId
  , csUrlList
  , csShowMessagePreview
  , csPostMap
  , csRecentChannel
  , csPostListOverlay
  , csMyTeam
  , csMode
  , csMessageSelect
  , csJoinChannelList
  , csConnectionStatus
  , csNames
  , csUsers
  , csChannel
  , csChannels
  , csChannelSelectUserMatches
  , csChannelSelectChannelMatches
  , csChannelSelectString
  , csMe
  , csEditState
  , timeZone

  , ChatEditState
  , emptyEditState
  , cedYankBuffer
  , cedSpellChecker
  , cedMisspellings
  , cedEditMode
  , cedCompletionAlternatives
  , cedCurrentCompletion
  , cedEditor
  , cedResetSpellCheckTimer
  , cedCurrentAlternative
  , cedMultiline
  , cedInputHistory
  , cedInputHistoryPosition
  , cedLastChannelInput

  , PostListOverlayState
  , postListSelected
  , postListPosts

  , ChatResources(ChatResources)
  , crEventQueue
  , crTheme
  , crSession
  , crSubprocessLog
  , crRequestQueue
  , crQuitCondition
  , crFlaggedPosts
  , crConn
  , crConfiguration

  , Cmd(..)
  , commandName
  , CmdArgs(..)

  , Keybinding(..)
  , lookupKeybinding

  , MH
  , runMHEvent
  , mh
  , mhSuspendAndResume
  , mhHandleEventLensed

  , requestQuit
  , clientPostToMessage
  , getMessageForPostId
  , withChannel
  , withChannelOrDefault
  , userList
  , hasUnread
  , channelNameFromMatch

  , userSigil
  , normalChannelSigil
  )
where

import           Prelude ()
import           Prelude.Compat

import           Brick (EventM, Next)
import qualified Brick
import           Brick.BChan
import           Brick.AttrMap (AttrMap)
import           Brick.Widgets.Edit (Editor, editor)
import           Brick.Widgets.List (List, list)
import qualified Control.Concurrent.STM as STM
import           Control.Concurrent.MVar (MVar)
import           Control.Exception (SomeException)
import qualified Control.Monad.State as St
import qualified Data.Foldable as F
import qualified Data.Sequence as Seq
import qualified Data.Set as S
import           Data.HashMap.Strict (HashMap)
import           Data.Time.Clock (UTCTime)
import           Data.Time.LocalTime (TimeZone)
import qualified Data.HashMap.Strict as HM
import           Data.List (sort)
import           Data.Maybe
import           Data.Monoid
import           Data.Set (Set)
import qualified Graphics.Vty as Vty
import           Lens.Micro.Platform ( at, makeLenses, lens, (&), (^.), (%~), (.~), (^?!)
                                     , _Just, Traversal', preuse )
import           Network.Mattermost
import           Network.Mattermost.Exceptions
import           Network.Mattermost.Lenses
import           Network.Mattermost.WebSocket
import           Network.Connection (HostNotResolved, HostCannotConnect)
import qualified Data.Text as T
import           System.Exit (ExitCode)
import           Text.Aspell (Aspell)

import           Zipper (Zipper, focusL)

import           InputHistory

import           Types.Channels
import           Types.Posts
import           Types.Messages
import           Types.Users

-- * Configuration

-- | A user password is either given to us directly, or a command
-- which we execute to find the password.
data PasswordSource =
    PasswordString T.Text
    | PasswordCommand T.Text
    deriving (Eq, Read, Show)

-- | These are all the values that can be read in our configuration
-- file.
data Config = Config
  { configUser           :: Maybe T.Text
  , configHost           :: Maybe T.Text
  , configTeam           :: Maybe T.Text
  , configPort           :: Int
  , configPass           :: Maybe PasswordSource
  , configTimeFormat     :: Maybe T.Text
  , configDateFormat     :: Maybe T.Text
  , configTheme          :: Maybe T.Text
  , configSmartBacktick  :: Bool
  , configURLOpenCommand :: Maybe T.Text
  , configActivityBell   :: Bool
  , configShowMessagePreview :: Bool
  , configEnableAspell   :: Bool
  , configAspellDictionary :: Maybe T.Text
  } deriving (Eq, Show)

-- * 'MMNames' structures

-- | The 'MMNames' record is for listing human-readable
--   names and mapping them back to internal IDs.
data MMNames = MMNames
  { _cnChans    :: [T.Text] -- ^ All channel names
  , _cnToChanId :: HashMap T.Text ChannelId
      -- ^ Mapping from channel names to 'ChannelId' values
  , _cnUsers    :: [T.Text] -- ^ All users
  , _cnToUserId :: HashMap T.Text UserId
      -- ^ Mapping from user names to 'UserId' values
  }

-- | An empty 'MMNames' record
emptyMMNames :: MMNames
emptyMMNames = MMNames mempty mempty mempty mempty

mkChanNames :: User -> HM.HashMap UserId User -> Seq.Seq Channel -> MMNames
mkChanNames myUser users chans = MMNames
  { _cnChans = sort
               [ preferredChannelName c
               | c <- F.toList chans, channelType c /= Direct ]
  , _cnToChanId = HM.fromList $
                  [ (preferredChannelName c, channelId c) | c <- F.toList chans ] ++
                  [ (userUsername u, c)
                  | u <- HM.elems users
                  , c <- lookupChan (getDMChannelName (getId myUser) (getId u))
                  ]
  , _cnUsers = sort (map userUsername (HM.elems users))
  , _cnToUserId = HM.fromList
                  [ (userUsername u, getId u) | u <- HM.elems users ]
  }
  where lookupChan n = [ c^.channelIdL
                       | c <- F.toList chans, c^.channelNameL == n
                       ]

-- ** 'MMNames' Lenses

makeLenses ''MMNames

-- * Internal Names and References

-- | This 'Name' type is the value used in `brick` to identify the
-- currently focused widget or state.
data Name = ChannelMessages ChannelId
          | MessageInput
          | ChannelList
          | HelpViewport
          | HelpText
          | ScriptHelpText
          | ChannelSelectString
          | CompletionAlternatives
          | JoinChannelList
          | UrlList
          | MessagePreviewViewport
          deriving (Eq, Show, Ord)

-- | The sum type of exceptions we expect to encounter on authentication
-- failure. We encode them explicitly here so that we can print them in
-- a more user-friendly manner than just 'show'.
data AuthenticationException =
    ConnectError HostCannotConnect
    | ResolveError HostNotResolved
    | LoginError LoginFailureException
    | OtherAuthError SomeException
    deriving (Show)

-- | Our 'ConnectionInfo' contains exactly as much information as is
-- necessary to start a connection with a Mattermost server
data ConnectionInfo =
    ConnectionInfo { ciHostname :: T.Text
                   , ciPort     :: Int
                   , ciUsername :: T.Text
                   , ciPassword :: T.Text
                   }

-- | We want to continue referring to posts by their IDs, but we don't want to
-- have to synthesize new valid IDs for messages from the client
-- itself (like error messages or informative client responses). To
-- that end, a PostRef can be either a PostId or a newly-generated
-- client ID
data PostRef
  = MMId PostId
  | CLId Int
    deriving (Eq, Show)

-- | For representing links to things in the 'open links' view
data LinkChoice = LinkChoice
  { _linkTime   :: UTCTime
  , _linkUser   :: T.Text
  , _linkName   :: T.Text
  , _linkURL    :: T.Text
  , _linkFileId :: Maybe FileId
  } deriving (Eq, Show)

makeLenses ''LinkChoice

-- Sigils
normalChannelSigil :: Char
normalChannelSigil = '~'

userSigil :: Char
userSigil = '@'

-- ** Channel-matching types

data ChannelSelectMatch =
    ChannelSelectMatch { nameBefore     :: T.Text
                       , nameMatched    :: T.Text
                       , nameAfter      :: T.Text
                       }
                       deriving (Eq, Show)

channelNameFromMatch :: ChannelSelectMatch -> T.Text
channelNameFromMatch (ChannelSelectMatch b m a) = b <> m <> a

data ChannelSelectPattern = CSP MatchType T.Text
                          deriving (Eq, Show)

data MatchType = Prefix | Suffix | Infix | Equal deriving (Eq, Show)


-- * Application State Values

data ProgramOutput =
    ProgramOutput { program :: FilePath
                  , programArgs :: [String]
                  , programStdout :: String
                  , programStdoutExpected :: Bool
                  , programStderr :: String
                  , programExitCode :: ExitCode
                  }

-- | 'ChatResources' represents configuration and
-- connection-related information, as opposed to
-- current model or view information. Information
-- that goes in the 'ChatResources' value should be
-- limited to information that we read or set up
-- prior to setting up the bulk of the application state.
data ChatResources = ChatResources
  { _crSession       :: Session
  , _crConn          :: ConnectionData
  , _crRequestQueue  :: RequestChan
  , _crEventQueue    :: BChan MHEvent
  , _crSubprocessLog :: STM.TChan ProgramOutput
  , _crTheme         :: AttrMap
  , _crQuitCondition :: MVar ()
  , _crConfiguration :: Config
  , _crFlaggedPosts  :: Set PostId
  }

-- | The 'ChatEditState' value contains the editor widget itself
--   as well as history and metadata we need for editing-related
--   operations.
data ChatEditState = ChatEditState
  { _cedEditor               :: Editor T.Text Name
  , _cedEditMode             :: EditMode
  , _cedMultiline            :: Bool
  , _cedInputHistory         :: InputHistory
  , _cedInputHistoryPosition :: HM.HashMap ChannelId (Maybe Int)
  , _cedLastChannelInput     :: HM.HashMap ChannelId (T.Text, EditMode)
  , _cedCurrentCompletion    :: Maybe T.Text
  , _cedCurrentAlternative   :: T.Text
  , _cedCompletionAlternatives :: [T.Text]
  , _cedYankBuffer           :: T.Text
  , _cedSpellChecker         :: Maybe Aspell
  , _cedResetSpellCheckTimer :: IO ()
  , _cedMisspellings         :: S.Set T.Text
  }

data EditMode =
    NewPost
    | Editing Post
    | Replying Message Post
      deriving (Show)

-- | We can initialize a new 'ChatEditState' value with just an
--   edit history, which we save locally.
emptyEditState :: InputHistory -> Maybe Aspell -> IO () -> ChatEditState
emptyEditState hist sp resetTimer = ChatEditState
  { _cedEditor               = editor MessageInput Nothing ""
  , _cedMultiline            = False
  , _cedInputHistory         = hist
  , _cedInputHistoryPosition = mempty
  , _cedLastChannelInput     = mempty
  , _cedCurrentCompletion    = Nothing
  , _cedCompletionAlternatives = []
  , _cedCurrentAlternative   = ""
  , _cedEditMode             = NewPost
  , _cedYankBuffer           = ""
  , _cedSpellChecker         = sp
  , _cedMisspellings         = mempty
  , _cedResetSpellCheckTimer = resetTimer
  }

-- | A 'RequestChan' is a queue of operations we have to perform
--   in the background to avoid blocking on the main loop
type RequestChan = STM.TChan (IO (MH ()))

-- | The 'HelpScreen' type represents the set of possible 'Help'
--   dialogues we have to choose from.
data HelpScreen
  = MainHelp
  | ScriptHelp
    deriving (Eq)

-- |  Help topics
data HelpTopic =
    HelpTopic { helpTopicName         :: T.Text
              , helpTopicDescription  :: T.Text
              , helpTopicScreen       :: HelpScreen
              , helpTopicViewportName :: Name
              }
              deriving (Eq)

-- | Mode type for the current contents of the post list overlay
data PostListContents
  = PostListFlagged
--   | PostListPinned ChannelId
--   | PostListSearch Text -- for the query
  deriving (Eq)

-- | The 'Mode' represents the current dominant UI activity
data Mode =
    Main
    | ShowHelp HelpTopic
    | ChannelSelect
    | UrlSelect
    | LeaveChannelConfirm
    | DeleteChannelConfirm
    | JoinChannel
    | ChannelScroll
    | MessageSelect
    | MessageSelectDeleteConfirm
    | PostListOverlay PostListContents
    deriving (Eq)

-- | We're either connected or we're not.
data ConnectionStatus = Connected | Disconnected

-- | This is the giant bundle of fields that represents the current
--  state of our application at any given time. Some of this should
--  be broken out further, but hasn't yet been.
data ChatState = ChatState
  { _csResources                   :: ChatResources
  , _csFocus                       :: Zipper ChannelId
  , _csNames                       :: MMNames
  , _csMe                          :: User
  , _csMyTeam                      :: Team
  , _csChannels                    :: ClientChannels
  , _csPostMap                     :: HashMap PostId Message
  , _csUsers                       :: Users
  , _timeZone                      :: TimeZone
  , _csEditState                   :: ChatEditState
  , _csMode                        :: Mode
  , _csShowMessagePreview          :: Bool
  , _csChannelSelectString         :: T.Text
  , _csChannelSelectChannelMatches :: ChannelSelectMap
  , _csChannelSelectUserMatches    :: ChannelSelectMap
  , _csRecentChannel               :: Maybe ChannelId
  , _csUrlList                     :: List Name LinkChoice
  , _csConnectionStatus            :: ConnectionStatus
  , _csJoinChannelList             :: Maybe (List Name Channel)
  , _csMessageSelect               :: MessageSelectState
  , _csPostListOverlay             :: PostListOverlayState
  }

newState :: ChatResources
         -> Zipper ChannelId
         -> User
         -> Team
         -> TimeZone
         -> InputHistory
         -> Maybe Aspell
         -> IO ()
         -> ChatState
newState rs i u m tz hist sp resetTimer = ChatState
  { _csResources                   = rs
  , _csFocus                       = i
  , _csMe                          = u
  , _csMyTeam                      = m
  , _csNames                       = emptyMMNames
  , _csChannels                    = noChannels
  , _csPostMap                     = HM.empty
  , _csUsers                       = noUsers
  , _timeZone                      = tz
  , _csEditState                   = emptyEditState hist sp resetTimer
  , _csMode                        = Main
  , _csShowMessagePreview          = configShowMessagePreview $ _crConfiguration rs
  , _csChannelSelectString         = ""
  , _csChannelSelectChannelMatches = mempty
  , _csChannelSelectUserMatches    = mempty
  , _csRecentChannel               = Nothing
  , _csUrlList                     = list UrlList mempty 2
  , _csConnectionStatus            = Connected
  , _csJoinChannelList             = Nothing
  , _csMessageSelect               = MessageSelectState Nothing
  , _csPostListOverlay             = PostListOverlayState mempty Nothing
  }

type ChannelSelectMap = HM.HashMap T.Text ChannelSelectMatch

data MessageSelectState =
    MessageSelectState { selectMessagePostId :: Maybe PostId }

data PostListOverlayState = PostListOverlayState
  { _postListPosts    :: Messages
  , _postListSelected :: Maybe PostId
  }

-- * MH Monad

-- | A value of type 'MH' @a@ represents a computation that can
-- manipulate the application state and also request that the
-- application quit
newtype MH a =
  MH { fromMH :: St.StateT (ChatState, ChatState -> EventM Name (Next ChatState))
                           (EventM Name) a }

-- | Run an 'MM' computation, choosing whether to continue or halt
--   based on the resulting
runMHEvent :: ChatState -> MH () -> EventM Name (Next ChatState)
runMHEvent st (MH mote) = do
  ((), (st', rs)) <- St.runStateT mote (st, Brick.continue)
  rs st'

-- | lift a computation in 'EventM' into 'MH'
mh :: EventM Name a -> MH a
mh = MH . St.lift

mhHandleEventLensed :: Lens' ChatState b -> (e -> b -> EventM Name b) -> e -> MH ()
mhHandleEventLensed ln f event = MH $ do
  (st, b) <- St.get
  n <- St.lift $ f event (st ^. ln)
  St.put (st & ln .~ n , b)

mhSuspendAndResume :: (ChatState -> IO ChatState) -> MH ()
mhSuspendAndResume mote = MH $ do
  (st, _) <- St.get
  St.put (st, \ _ -> Brick.suspendAndResume (mote st))

-- | This will request that after this computation finishes the
-- application should exit
requestQuit :: MH ()
requestQuit = MH $ do
  (st, _) <- St.get
  St.put (st, Brick.halt)

instance Functor MH where
  fmap f (MH x) = MH (fmap f x)

instance Applicative MH where
  pure x = MH (pure x)
  MH f <*> MH x = MH (f <*> x)

instance Monad MH where
  return x = MH (return x)
  MH x >>= f = MH (x >>= \ x' -> fromMH (f x'))

-- We want to pretend that the state is only the ChatState, rather
-- than the ChatState and the Brick continuation
instance St.MonadState ChatState MH where
  get = fst `fmap` MH St.get
  put st = MH $ do
    (_, c) <- St.get
    St.put (st, c)

instance St.MonadIO MH where
  liftIO = MH . St.liftIO

-- | This represents any event that we might care about in the
--   main application loop
data MHEvent
  = WSEvent WebsocketEvent
    -- ^ For events that arise from the websocket
  | RespEvent (MH ())
    -- ^ For the result values of async IO operations
  | AsyncErrEvent SomeException
    -- ^ For errors that arise in the course of async IO operations
  | RefreshWebsocketEvent
    -- ^ Tell our main loop to refresh the websocket connection
  | WebsocketDisconnect
  | WebsocketConnect

-- ** Application State Lenses

makeLenses ''ChatResources
makeLenses ''ChatState
makeLenses ''ChatEditState
makeLenses ''PostListOverlayState

-- ** Utility Lenses
csCurrentChannelId :: Lens' ChatState ChannelId
csCurrentChannelId = csFocus.focusL

csCurrentChannel :: Lens' ChatState ClientChannel
csCurrentChannel =
  lens (\ st -> findChannelById (st^.csCurrentChannelId) (st^.csChannels) ^?! _Just)
       (\ st n -> st & csChannels %~ addChannel (st^.csCurrentChannelId) n)

csChannel :: ChannelId -> Traversal' ChatState ClientChannel
csChannel cId =
  csChannels . channelByIdL cId

withChannel :: ChannelId -> (ClientChannel -> MH ()) -> MH ()
withChannel cId = withChannelOrDefault cId ()

withChannelOrDefault :: ChannelId -> a -> (ClientChannel -> MH a) -> MH a
withChannelOrDefault cId deflt mote = do
  chan <- preuse (csChannel(cId))
  case chan of
    Nothing -> return deflt
    Just c  -> mote c

-- ** 'ChatState' Helper Functions

getMessageForPostId :: ChatState -> PostId -> Maybe Message
getMessageForPostId st pId = st^.csPostMap.at(pId)

getUsernameForUserId :: ChatState -> UserId -> Maybe T.Text
getUsernameForUserId st uId = _uiName <$> findUserById uId (st^.csUsers)

clientPostToMessage :: ChatState -> ClientPost -> Message
clientPostToMessage st cp = Message
  { _mText          = cp^.cpText
  , _mUserName      = case cp^.cpUserOverride of
    Just n
      | cp^.cpType == NormalPost -> Just (n <> "[BOT]")
    _ -> getUsernameForUserId st =<< cp^.cpUser
  , _mDate          = cp^.cpDate
  , _mType          = CP $ cp^.cpType
  , _mPending       = cp^.cpPending
  , _mDeleted       = cp^.cpDeleted
  , _mAttachments   = cp^.cpAttachments
  , _mInReplyToMsg  =
    case cp^.cpInReplyToPost of
      Nothing  -> NotAReply
      Just pId -> InReplyTo pId
  , _mPostId        = Just $ cp^.cpPostId
  , _mReactions     = cp^.cpReactions
  , _mOriginalPost  = Just $ cp^.cpOriginalPost
  , _mFlagged       = False
  , _mChannelId     = Just $ cp^.cpChannelId
  }

-- * Slash Commands

-- | The 'CmdArgs' type represents the arguments to a slash-command;
--   the type parameter represents the argument structure.
data CmdArgs :: * -> * where
  NoArg    :: CmdArgs ()
  LineArg  :: T.Text -> CmdArgs T.Text
  TokenArg :: T.Text -> CmdArgs rest -> CmdArgs (T.Text, rest)

-- | A 'CmdExec' value represents the implementation of a command
--   when provided with its arguments
type CmdExec a = a -> MH ()

-- | A 'Cmd' packages up a 'CmdArgs' specifier and the 'CmdExec'
--   implementation with a name and a description.
data Cmd = forall a. Cmd
  { cmdName    :: T.Text
  , cmdDescr   :: T.Text
  , cmdArgSpec :: CmdArgs a
  , cmdAction  :: CmdExec a
  }

-- | Helper function to extract the name out of a 'Cmd' value
commandName :: Cmd -> T.Text
commandName (Cmd name _ _ _ ) = name

-- * Keybindings

-- | A 'Keybinding' represents a keybinding along with its
--   implementation
data Keybinding =
    KB { kbDescription :: T.Text
       , kbEvent :: Vty.Event
       , kbAction :: MH ()
       }

-- | Find a keybinding that matches a Vty Event
lookupKeybinding :: Vty.Event -> [Keybinding] -> Maybe Keybinding
lookupKeybinding e kbs = listToMaybe $ filter ((== e) . kbEvent) kbs

-- *  Channel Updates and Notifications

hasUnread :: ChatState -> ChannelId -> Bool
hasUnread st cId = maybe False id $ do
  chan <- findChannelById cId (st^.csChannels)
  lastViewTime <- chan^.ccInfo.cdViewed
  return (chan^.ccInfo.cdUpdated > lastViewTime)

userList :: ChatState -> [UserInfo]
userList st = filter showUser $ allUsers (st^.csUsers)
  where showUser u = not (isSelf u) && (u^.uiInTeam)
        isSelf u = (st^.csMe.userIdL) == (u^.uiId)
