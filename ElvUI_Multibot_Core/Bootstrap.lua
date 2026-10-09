local addonName, MB = ...

_G.ElvUI_Multibot_Core = MB

MB.addonName = addonName
MB.name = "ElvUI Multibot Core"
MB.version = GetAddOnMetadata(addonName, "Version") or "0.1.0-alpha1"
MB.API_VERSION = 1
MB.PROTOCOL_VERSION = "1"
MB.BRIDGE_PREFIX = "MBOT"
MB.BRIDGE_REFERENCE = "MultiBot client protocol reference"

MB.initialized = false
MB.started = false
MB.sessionEpoch = 0
MB.sequence = 0
MB.timers = {}
MB.timerSequence = 0

MB.modules = {}
MB.services = {}
MB.contextActions = {}
MB.contextActionByModule = {}
MB.dataDomains = {}
MB.actions = {}
MB.cache = {}
MB.interests = {}
MB.pendingReads = {}
MB.pendingReadSequence = 0
MB.subscriptions = {}
MB.subscriptionByToken = {}
MB.subscriptionSequence = 0
MB.botRegistry = {}
MB.botRegistryReady = false
MB.botRegistryReadyEpoch = 0
MB.selections = {}
MB.transactions = {}
MB.transactionSequence = 0
MB.snapshotProviders = {}
MB.snapshotProviderByModule = {}
MB.snapshotRequests = {}
MB.snapshotRequestSequence = 0
MB.snapshotActiveByGuid = {}
MB.snapshotStore = nil
MB.managedStore = nil
MB.lastKnownStore = nil
MB.lastKnownPending = {}
MB.managedSessionAuthByGuid = {}
MB.managedGroupStore = nil
MB.managedGroupLifecycleRequests = {}
MB.managedGroupLifecycleGuidReservations = {}
MB.managedGroupLifecycleRequestSequence = 0
MB.lifecycleRequests = {}
MB.lifecycleRequestSequence = 0

MB.bridge = {
    prefix = MB.BRIDGE_PREFIX,
    protocolWanted = MB.PROTOCOL_VERSION,
    connected = false,
    bootstrapPending = false,
    handshakeReady = false,
    protocol = nil,
    server = nil,
    capabilities = {},
    capabilityBatchActive = false,
    capabilitiesResolved = false,
    observedExtensions = {},
    frames = {},
    actionTokens = {},
    stateOrder = 0,
    stateLatestOrderByBot = {},
    stateGlobalLatestToken = nil,
    altRosterBatch = nil,
    lastHelloAt = 0,
    lastPingAt = 0,
    lastPongAt = 0,
    lastRxAt = 0,
    lastTxAt = 0,
    lastError = nil,
    bootstrapBurstId = 0,
}

local E, L, V, P, G
if type(ElvUI) == "table" then
    E, L, V, P, G = unpack(ElvUI)
end
MB.E, MB.L, MB.V, MB.P, MB.G = E, L, V, P, G

MB.defaults = {
    profileVersion = 1,
    enabled = true,
    bridge = {
        enabled = true,
        heartbeatInterval = 15,
        handshakeRetryInterval = 5,
        disconnectTimeout = 35,
        requestTimeout = 8,
        bootstrapDelay = 0.40,
    },
    updates = {
        roster = 5,
        altRoster = 15,
        state = 8,
        detail = 30,
        stats = 15,
        pvpStats = 30,
        inventory = 30,
        spellbook = 60,
        talents = 60,
        glyphs = 60,
        skills = 90,
        reputations = 120,
        emblems = 60,
        professions = 60,
        quests = 30,
        formations = 30,
    },
    chat = {
        enabled = true,
        minSendInterval = 0.25,
        suppressAutomaticNoise = true,
        suppressionTTL = 8,
    },
    selections = {
        saved = {},
    },
    diagnostics = {
        debug = false,
        maxLogEntries = 180,
        observeUnknownProtocol = true,
    },
}

-- ElvUI plugin profile defaults must be registered before E:Initialize() builds AceDB.
-- Core itself is initialized later through LibElvUIPlugin's post-initialize hook.
if type(MB.P) == "table" then
    MB.P.multibotCore = MB.defaults
end

MB.runtime = {
    log = {},
    counters = {
        bridgeTx = 0,
        bridgeRx = 0,
        readsStarted = 0,
        readsDeduped = 0,
        readsCompleted = 0,
        readsFailed = 0,
        cacheCommits = 0,
        cacheChanges = 0,
        chatTx = 0,
        actionsStarted = 0,
        actionsCompleted = 0,
    },
}
