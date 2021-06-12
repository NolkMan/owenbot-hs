{-# LANGUAGE OverloadedStrings #-}

module Admin ( receivers, sendGitInfoChan, sendInstanceInfoChan ) where

import qualified Data.Text as T
import           Discord.Types
import           Discord                ( DiscordHandler
                                        , stopDiscord, restCall
                                        )
import           Discord.Requests as R
import           UnliftIO               ( liftIO )
import           Data.Char              ( isSpace )
import Data.Maybe                       ( fromJust )
import           Control.Monad          ( unless
                                        , void
                                        )
import           Network.BSD            ( getHostName )
import           Text.Regex.TDFA        ( (=~) )

import           System.Directory       ( doesPathExist )
import           System.Posix.Process   ( getProcessID )
import qualified System.Process as Process

import           Command
import           Owoifier               ( owoify )

import           Utils                  ( newDevCommand
                                        , newModCommand
                                        , sendMessageChan
                                        , captureCommandOutput
                                        , devIDs
                                        , update
                                        , developerRequirement
                                        )
import           Status                 ( editStatusFile
                                        , updateStatus
                                        )
import           CSV                    ( readSingleColCSV
                                        , writeSingleColCSV
                                        )

receivers :: [Message -> DiscordHandler ()]
receivers =
    [ sendGitInfo
    , sendInstanceInfo
    , restartOwen
    , stopOwen
    , updateOwen
    , runCommand setStatus
    , runCommand someComplexThing
    , runCommand devs
    , lockdown
    , unlock
    , lockAll
    , unlockAll
    ]

rstrip :: T.Text -> T.Text
rstrip = T.reverse . T.dropWhile isSpace . T.reverse

-- captureCommandOutput appends newlines automatically
gitLocal, gitRemote, commitsAhead :: IO T.Text
gitLocal = captureCommandOutput "git rev-parse HEAD"
gitRemote = captureCommandOutput "git fetch"
  >> captureCommandOutput "git rev-parse origin/main"
commitsAhead = captureCommandOutput "git fetch"
  >> captureCommandOutput "git rev-list --count HEAD..origin/main"

isGitRepo :: IO Bool
isGitRepo = doesPathExist ".git"

sendGitInfo :: Message -> DiscordHandler ()
sendGitInfo m = newDevCommand m "repo" $ \_ ->
    sendGitInfoChan $ messageChannel m

sendGitInfoChan :: (MonadDiscord m, MonadIO m) => ChannelId -> m ()
sendGitInfoChan chan = do
    inRepo <- liftIO isGitRepo
    if not inRepo then
        sendMessageChan chan "Not in git repo (sorry)!"
    else do
        loc <- liftIO gitLocal
        remote <- liftIO gitRemote
        commits <- liftIO commitsAhead
        sendMessageChan chan ("Git Status Info: \n" <>
                              "Local at: "  <> loc <>
                              "Remote at: " <> remote <>
                              "Remote is "  <> rstrip commits <> " commits ahead")

sendInstanceInfo :: Message -> DiscordHandler ()
sendInstanceInfo
  = runCommand
  . requires developerRequirement
  . command "instance" $ \m -> 
        sendInstanceInfoChan $ messageChannel m

sendInstanceInfoChan :: (MonadDiscord m, MonadIO m) => ChannelId -> m ()
sendInstanceInfoChan chan = do
    host <- liftIO getHostName
    pid  <- liftIO getProcessID
    sendMessageChan chan ("Instance Info: \n" <>
                          "Host: "            <> T.pack host <> "\n" <>
                          "Process ID: "      <> T.pack (show pid))

restartOwen :: Message -> DiscordHandler ()
restartOwen
  = runCommand
  . requires developerRequirement
  . command "restart" $ \m -> do
        sendMessageChan (messageChannel m) "Restarting"
        void $ liftIO $ Process.spawnCommand "owenbot-exe"
        stopDiscord

-- | Stops the entire Discord chain.
stopOwen :: Message -> DiscordHandler ()
stopOwen
  = runCommand
  . requires developerRequirement
  . command "stop" $ \m -> do
        sendMessageChan (messageChannel m) "Stopping."
        stopDiscord

updateOwen :: Message -> DiscordHandler ()
updateOwen
  = runCommand
  . requires developerRequirement
  . command "update" $ \m -> do
        respond m "Updating Owen"
        result <- liftIO update
        if result then
            respond m $ owoify "Finished update"
        else
            respond m $ owoify "Failed to update! Please check the logs"

-- DEV COMMANDS
getDevs :: IO [T.Text]
getDevs = readSingleColCSV devIDs

setDevs :: [T.Text] -> IO ()
setDevs = writeSingleColCSV devIDs

devs :: Command DiscordHandler
devs
    = requires developerRequirement
    . help "List/add/remove registered developer role IDs"
    . command "devs" $ \m maybeActionValue -> do
        contents <- liftIO getDevs
        case maybeActionValue :: Maybe (T.Text, RoleId) of
            Nothing -> do
                unless (null contents) $
                    respond m $ T.intercalate "\n" contents
            Just ("add", roleId) -> do
                liftIO $ setDevs (T.pack (show roleId):contents)
                respond m "Added!"
            Just ("remove", roleId) -> do
                liftIO $ setDevs (filter (/= T.pack (show roleId)) contents)
                respond m "Removed!"

statusRE :: T.Text
statusRE = "(online|idle|dnd|invisible) "
           <> "(playing|streaming|competing|listening to) "
           <> "(.*)"

-- | This can't be polymoprhic because updateStatus requires gateway specific
-- things.
setStatus :: Command DiscordHandler
setStatus
    = command "status"
    $ \msg newStatus newType (Remaining newName) -> do
        updateStatus newStatus newType newName
        liftIO $ editStatusFile newStatus newType newName
        respond msg
            "Status updated :) Keep in mind it may take up to a minute for your client to refresh."

someComplexThing :: (MonadDiscord m) => Command m
someComplexThing
    = command "complex"
    $ \msg words -> do
        respond msg $
            "Length: " <> (T.pack . show . length) words <> "\n" <>
                "Caught items: \n" <> T.intercalate "\n" words


data Lock = Lockdown | Unlock deriving (Show, Eq)

lockdown :: Message -> DiscordHandler ()
lockdown m = newModCommand m "lockdown" $ \captures -> do
    let chan = messageChannel m
    eChannelObj <- restCall $ R.GetChannel chan
    case eChannelObj of
        Left err -> liftIO $ print err
        Right channel -> do
            case channel of
                ChannelText _ guild _ _ _ _ _ _ _ _ -> do
                    -- Guild is used in place of role ID as guildID == @everyone role ID
                    restCall $ lockdownChan chan guild Lockdown
                    sendMessageChan chan $ owoify "Locking Channel. To unlock use :unlock"

                _ -> do sendMessageChan (messageChannel m) $ owoify "channel is not a valid Channel"

unlock :: Message -> DiscordHandler ()
unlock m = newModCommand m "unlock" $ \captures -> do
  let chan = messageChannel m

  eChannelObj <- restCall $ R.GetChannel chan
  case eChannelObj of
    Left err -> liftIO $ print err
    Right channel -> do
      case channel of
        ChannelText _ guild _ _ _ _ _ _ _ _ -> do
          -- Guild is used in place of role ID as guildID == @everyone role ID
          restCall $ lockdownChan chan guild Unlock
          sendMessageChan chan $ owoify "Unlocking channel, GLHF!"
        _ -> do sendMessageChan (messageChannel m) $ owoify "channel is not a valid Channel (How the fuck did you pull that off?)"


lockdownChan :: ChannelId -> OverwriteId -> Lock -> ChannelRequest ()
lockdownChan chan guild b = do
    let switch  = case b of Lockdown -> fst; Unlock -> snd
    let swapPermOpts = ChannelPermissionsOpts
                            { channelPermissionsOptsAllow = switch (0, 0x0000000800)
                            , channelPermissionsOptsDeny  = switch (0x0000000800, 0)
                            , channelPermissionsOptsType  = ChannelPermissionsOptsRole
                            }
    R.EditChannelPermissions chan guild swapPermOpts


--https://discordapi.com/permissions.html#2251673153
unlockAll :: Message -> DiscordHandler ()
unlockAll m = newModCommand m "unlockAll" $ \_ -> do
    let opts = ModifyGuildRoleOpts Nothing (Just 2251673153) Nothing Nothing Nothing

    let g = fromJust $ messageGuild m
    restCall $ ModifyGuildRole g g opts
    sendMessageChan (messageChannel m) "unlocked"

-- https://discordapi.com/permissions.html#2251671105
lockAll :: Message -> DiscordHandler ()
lockAll m = newModCommand m "lockAll" $ \_ -> do
  let opts = ModifyGuildRoleOpts Nothing (Just 2251671105) Nothing Nothing Nothing

  let g = fromJust $ messageGuild m
  restCall $ ModifyGuildRole g g opts
  sendMessageChan (messageChannel m) "locked"

