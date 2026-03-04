module AgentMonitor.Types where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)

-- | Unique identifier for an agent. The main session uses "main".
-- Subagents use the tool_use id of the Task call that spawned them.
type AgentId = Text

-- | Status of an agent
data AgentStatus
  = Running
  | Completed
  | Failed
  deriving (Eq, Show)

-- | Information about a single agent (main session or subagent)
data AgentInfo = AgentInfo
  { aiId          :: AgentId
  , aiDescription :: Text
  , aiStatus      :: AgentStatus
  , aiParentId    :: Maybe AgentId    -- Nothing for main session
  , aiChildren    :: [AgentId]        -- Ordered list of child agent ids
  , aiInputTokens :: Int
  , aiOutputTokens :: Int
  , aiToolCalls   :: Int
  , aiStartTime   :: Maybe UTCTime
  , aiLastTime    :: Maybe UTCTime
  , aiLastOutput  :: Text             -- Last text output from assistant
  , aiAgentId     :: Maybe Text       -- The agentId field from JSONL (hex string)
  } deriving (Show)

-- | The full application state
data AppState = AppState
  { asAgents       :: Map AgentId AgentInfo
  , asRootId       :: AgentId              -- Always "main"
  , asSelectedId   :: AgentId              -- Currently selected agent
  , asFlatOrder    :: [AgentId]            -- Flattened tree order for navigation
  , asFilePath     :: FilePath
  , asFilePos      :: Int                  -- Byte offset for tailing
  , asSessionStart :: Maybe UTCTime
  } deriving (Show)

-- | Custom events for brick
data CustomEvent
  = FileUpdated    -- New lines available
  | Tick           -- Periodic refresh
  deriving (Show)

-- | Resource names for brick widgets
data ResourceName
  = AgentTree
  | DetailPanel
  deriving (Eq, Ord, Show)

-- | Create a fresh main agent
mkMainAgent :: AgentInfo
mkMainAgent = AgentInfo
  { aiId           = "main"
  , aiDescription  = "Main Session"
  , aiStatus       = Running
  , aiParentId     = Nothing
  , aiChildren     = []
  , aiInputTokens  = 0
  , aiOutputTokens = 0
  , aiToolCalls    = 0
  , aiStartTime    = Nothing
  , aiLastTime     = Nothing
  , aiLastOutput   = ""
  , aiAgentId      = Nothing
  }

-- | Create a new subagent
mkSubAgent :: AgentId -> AgentId -> Text -> Maybe UTCTime -> AgentInfo
mkSubAgent agentId parentId desc startTime = AgentInfo
  { aiId           = agentId
  , aiDescription  = desc
  , aiStatus       = Running
  , aiParentId     = Just parentId
  , aiChildren     = []
  , aiInputTokens  = 0
  , aiOutputTokens = 0
  , aiToolCalls    = 0
  , aiStartTime    = startTime
  , aiLastTime     = startTime
  , aiLastOutput   = ""
  , aiAgentId      = Nothing
  }
