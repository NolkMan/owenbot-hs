{-# language OverloadedStrings, DeriveGeneric #-}

module MCServer ( receivers ) where
    
import           Data.Aeson
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import           Data.Maybe             ( fromJust )
import           Discord                ( DiscordHandler )
import           Discord.Types          ( Message ( messageChannel ) )
import           GHC.Generics
import           Network.HTTP.Conduit   ( simpleHttp )
import           UnliftIO               ( liftIO )

import           Command
import           CSV                    ( writeSingleColCSV
                                        , readSingleColCSV
                                        )
import           Utils                  ( modPerms )
import           Owoifier               ( owoify )

receivers :: [Message -> DiscordHandler ()]
receivers =
    [ runCommand getStatus
    , runCommand setServer
    ]

data ServerStatus = ServerStatus {
    ip              :: String,
    online          :: Bool,
    motd            :: Maybe ServerMOTD,
    players         :: Maybe ServerPlayers,
    version         :: Maybe String,
    software        :: Maybe String
} deriving (Show, Generic)

instance FromJSON ServerStatus
instance ToJSON ServerStatus

data ServerMOTD = ServerMOTD {
    raw             :: [String],
    clean           :: [String],
    html            :: [String]
} deriving (Show, Generic)

instance FromJSON ServerMOTD
instance ToJSON ServerMOTD

data ServerPlayers = ServerPlayers {
    players_online  :: Integer,
    players_max     :: Integer
} deriving (Show, Generic)

instance FromJSON ServerPlayers where
    parseJSON = genericParseJSON $ defaultOptions {
        fieldLabelModifier = playersPrefix
        }
instance ToJSON ServerPlayers

playersPrefix :: String -> String
playersPrefix "players_online" = "online"
playersPrefix "players_max" = "max"

jsonURL :: String
jsonURL = "https://api.mcsrvstat.us/2/"

getJSON :: T.Text -> IO B.ByteString
getJSON server_ip = simpleHttp $ jsonURL <> T.unpack server_ip

fetchServerDetails :: T.Text -> IO (Either String String)
fetchServerDetails server_ip = do
    serverDeetsM <- (eitherDecode <$> getJSON server_ip) :: IO (Either String ServerStatus)
    pure $ case serverDeetsM of
        Left err          -> Left err
        Right serverDeets -> do
            let serverStatus = concat [
                                   ":pick: The Minecraft server is ",
                                   "**", if online serverDeets then "online" else "offline", "**. "
                               ]
            if not (online serverDeets) then
                Right serverStatus
            else do
                let playersonline = show $ players_online $ fromJust $ players serverDeets
                let playersmax = show $ players_max $ fromJust $ players serverDeets
                let motdclean = alwaysHead $ clean $ fromJust $ motd serverDeets
                let ipstr = ip serverDeets
                let ver = fromJust $ version serverDeets
                let onlineServerDeets = concat [
                                            "Current Players: ", playersonline, "/", playersmax, ".\n",
                                            "Message of the Day: *", motdclean, "*\n",
                                            "Come join at `", ipstr, "` on version `", ver, "`"
                                        ]
                Right $ serverStatus <> onlineServerDeets

alwaysHead :: [String] -> String
alwaysHead [] = ""
alwaysHead (a:as) = a

getStatus :: (MonadDiscord m, MonadIO m) => Command m
getStatus = command "minecraft" $ \m -> do
    server_ip <- liftIO readServerIP
    deets <- liftIO $ fetchServerDetails server_ip
    case deets of 
        Left err   -> liftIO (print err) >> respond m (T.pack err)
        Right nice -> respond m $ owoify $ T.pack nice

readServerIP :: IO T.Text
readServerIP = do
    server_ip <- readSingleColCSV "mcServer.csv"
    if null server_ip
        then writeSingleColCSV "mcServer.csv" ["123.456.789.123"] >> pure "123.456.789.123"
        else pure $ head server_ip

setServer :: (MonadDiscord m, MonadIO m) => Command m
setServer
    = requires modPerms
    $ command "setMinecraft"
    $ \m server_ip -> do
        liftIO $ writeSingleColCSV "mcServer.csv" [server_ip]
        respond m "Success!"
