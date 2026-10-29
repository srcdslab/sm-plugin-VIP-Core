#define  CHARSET "utf8mb4"
#define  COLLATION "utf8mb4_unicode_ci"

//#define  CHARSET "utf8"
//#define  COLLATION "utf8_unicode_ci"

int g_iDBConnectRetries;

void DB_OnPluginStart()
{
	DB_Connect();
}

void DB_Connect()
{
	//	DebugMessage("DB_Connect: %b", g_bIsVIPLoaded);
	DBG_Database("DB_Connect");

	if (GLOBAL_INFO & IS_LOADING)
	{
		return;
	}

	if (g_hDatabase != null)
	{
		UNSET_BIT(GLOBAL_INFO, IS_LOADING);
		return;
	}

	SET_BIT(GLOBAL_INFO, IS_LOADING);

	if (SQL_CheckConfig("vip_core")) // "vip_core"
	{
		Database.Connect(OnDBConnect, "vip_core", 0);
	}
	else
	{
		char szError[256];
		g_hDatabase = SQLite_UseDatabase("vip_core", SZF(szError));
		OnDBConnect(g_hDatabase, szError, 1);
	}
}

public void OnDBConnect(Database hDatabase, const char[] szError, any data)
{
	if (hDatabase == null || szError[0])
	{
		delete hDatabase;
		g_hDatabase = null;
		UNSET_BIT(GLOBAL_INFO, IS_MySQL);
		UNSET_BIT(GLOBAL_INFO, IS_LOADING);

		// Retry with a backoff: 5s, 10s, 20s, ... up to 2 minutes
		float fDelay = 5.0 * float(1 << (g_iDBConnectRetries < 5 ? g_iDBConnectRetries : 5));
		if (fDelay > 120.0)
		{
			fDelay = 120.0;
		}
		g_iDBConnectRetries++;

		LogError("OnDBConnect: %s (retrying in %.0f seconds)", szError, fDelay);
		CreateTimer(fDelay, Timer_DB_Reconnect);
		return;
	}

	g_iDBConnectRetries = 0;
	g_hDatabase = hDatabase;

	if (data == 1)
	{
		UNSET_BIT(GLOBAL_INFO, IS_MySQL);
	}
	else
	{
		char szDriver[8];
		g_hDatabase.Driver.GetIdentifier(SZF(szDriver));

		if (strcmp(szDriver, "mysql", false) == 0)
		{
			SET_BIT(GLOBAL_INFO, IS_MySQL);

			// Once per connection, before any query: the driver keeps it across auto-reconnects
			if (!g_hDatabase.SetCharset(CHARSET))
			{
				g_hDatabase.Query(SQL_Callback_ErrorCheck, "SET NAMES '" ... CHARSET ... "'", _, DBPrio_High);
			}
		}
		else
		{
			UNSET_BIT(GLOBAL_INFO, IS_MySQL);
		}
	}

	DBG_Database("OnDBConnect %x, %u - > (MySQL: %b)", g_hDatabase, g_hDatabase, GLOBAL_INFO & IS_MySQL);

	CreateTables();
}

public Action Timer_DB_Reconnect(Handle hTimer)
{
	DB_Connect();
	return Plugin_Stop;
}

void CreateTables()
{
	DBG_Database("CreateTables");

	if (GLOBAL_INFO & IS_MySQL)
	{
		#if USE_MORE_SERVERS
		FormatEx(SZF(g_szSID), " AND (`sid` = %d OR `sid` = 0)", g_CVAR_iServerID);
		#else
		FormatEx(SZF(g_szSID), " AND `sid` = %d", g_CVAR_iServerID);
		#endif
		g_hDatabase.Query(SQL_Callback_TableCreate,	"CREATE TABLE IF NOT EXISTS `vip_users` (\
					`account_id` INT NOT NULL, \
					`name` VARCHAR(64) NOT NULL default 'unknown' COLLATE '" ... COLLATION ... "', \
					`lastvisit` INT UNSIGNED NOT NULL default 0, \
					`sid` INT UNSIGNED NOT NULL, \
					`group` VARCHAR(64) NOT NULL, \
					`expires` INT UNSIGNED NOT NULL default 0, \
					CONSTRAINT pk_PlayerID PRIMARY KEY (`account_id`, `sid`), \
					KEY `expires` (`expires`), \
					KEY `lastvisit` (`lastvisit`) \
					) DEFAULT CHARSET=" ... CHARSET ... ";", _, DBPrio_High);

		// Existing installs: add the indexes used by the expired/outdated cleanup (error 1061 = already there)
		g_hDatabase.Query(SQL_Callback_AddIndex, "ALTER TABLE `vip_users` ADD INDEX `expires` (`expires`);", _, DBPrio_High);
		g_hDatabase.Query(SQL_Callback_AddIndex, "ALTER TABLE `vip_users` ADD INDEX `lastvisit` (`lastvisit`);", _, DBPrio_High);
	}
	else
	{
		g_szSID[0] = 0;
		g_hDatabase.Query(SQL_Callback_TableCreate,	"CREATE TABLE IF NOT EXISTS `vip_users` (\
				`account_id` INTEGER PRIMARY KEY NOT NULL, \
				`name` VARCHAR(64) NOT NULL default 'unknown', \
				`lastvisit` INTEGER UNSIGNED NOT NULL default 0, \
				`group` VARCHAR(64) NOT NULL, \
				`expires` INTEGER UNSIGNED NOT NULL default 0);", _, DBPrio_High);

		g_hDatabase.Query(SQL_Callback_AddIndex, "CREATE INDEX IF NOT EXISTS `vip_users_expires` ON `vip_users` (`expires`);", _, DBPrio_High);
		g_hDatabase.Query(SQL_Callback_AddIndex, "CREATE INDEX IF NOT EXISTS `vip_users_lastvisit` ON `vip_users` (`lastvisit`);", _, DBPrio_High);
	}
}

public void SQL_Callback_AddIndex(Database hOwner, DBResultSet hResult, const char[] szError, any data)
{
	// 1061: Duplicate key name, the index already exists
	if (szError[0] && StrContains(szError, "Duplicate key name", false) == -1)
	{
		LogError("SQL_Callback_AddIndex: %s", szError);
	}
}

public void SQL_Callback_TableCreate(Database hOwner, DBResultSet hResult, const char[] szError, any data)
{
	DBG_SQL_Response("SQL_Callback_TableCreate");

	if (szError[0])
	{
		SetFailState("SQL_Callback_TableCreate: %s", szError);
		return;
	}

	UNSET_BIT(GLOBAL_INFO, IS_LOADING);

	OnReadyToStart();

	// Load all VIPs into cache on first connection
	if (g_bFirstVIPLoading)
	{
		DB_LoadAllVIPsToCache();
		g_bFirstVIPLoading = false;
	}

	UTIL_ReloadVIPPlayers(0, false);

	if (g_CVAR_iDeleteExpired != -1 || g_CVAR_iOutdatedExpired != -1)
	{
		RemoveExpAndOutPlayers();
	}
}

void RemoveExpAndOutPlayers()
{
	if (!g_hDatabase)
	{
		return;
	}

	if (g_CVAR_iDeleteExpired >= 0)
	{
		char szQuery[256];
		FormatEx(SZF(szQuery), "SELECT `account_id`, `name`, `group` FROM `vip_users` WHERE `expires` > 0 AND `expires` < %d%s;", GetTime() - (g_CVAR_iDeleteExpired == 0 ? 1:g_CVAR_iDeleteExpired)*86400, g_szSID);

		DBG_SQL_Query(szQuery);
		g_hDatabase.Query(SQL_Callback_SelectExpiredAndOutdated, szQuery, REASON_EXPIRED, DBPrio_Low);
	}

	if (g_CVAR_iOutdatedExpired > 0)
	{
		char szQuery[256];
		FormatEx(SZF(szQuery), "SELECT `account_id`, `name`, `group` FROM `vip_users` WHERE `lastvisit` > 0 AND `lastvisit` < %d%s;", (GetTime() - g_CVAR_iOutdatedExpired*86400), g_szSID);

		DBG_SQL_Query(szQuery);
		g_hDatabase.Query(SQL_Callback_SelectExpiredAndOutdated, szQuery, REASON_OUTDATED, DBPrio_Low);
	}
}

public void SQL_Callback_ErrorCheck(Database hOwner, DBResultSet hResult, const char[] szError, any data)
{
	DBG_SQL_Response("SQL_Callback_ErrorCheck");

	if (szError[0])
	{
		LogError("SQL_Callback_ErrorCheck: %s", szError);
	}
}

void DB_UpdateClient(int iClient, const char[] szDbName = NULL_STRING)
{
	int iClientID;
	g_hFeatures[iClient].GetValue(KEY_CID, iClientID);

	char szQuery[256];

	if (g_CVAR_bUpdateName || !strcmp(szDbName, "unknown"))
	{
		char szName[MNL];
		GetClientName(iClient, SZF(szName));
		g_hDatabase.Format(SZF(szQuery), "UPDATE `vip_users` SET `name` = '%s', `lastvisit` = %d WHERE `account_id` = %d%s;", szName, GetTime(), iClientID, g_szSID);
	}
	else
	{
		FormatEx(SZF(szQuery), "UPDATE `vip_users` SET `lastvisit` = %d WHERE `account_id` = %d%s;", GetTime(), iClientID, g_szSID);
	}

	DBG_SQL_Query(szQuery);
	g_hDatabase.Query(SQL_Callback_ErrorCheck, szQuery, _, DBPrio_Low);
}

void DB_RemoveClientFromID(int iAdmin = 0,
							int iClient = 0,
							int iClientID = 0,
							bool bNotify,
							const char[] szSourceName = NULL_STRING,
							const char[] szSourceGroup = NULL_STRING,
							const char[] szByWho = NULL_STRING)
{
	DebugMessage("DB_RemoveClientFromID %N (%d): - > iClientID: %d, : bNotify: %b", iClient, iClient, iClientID, bNotify)
	char szQuery[256], szName[MNL], szGroup[64];
	DataPack hDataPack = new DataPack();

	if(iClient)
	{
		if(szSourceName[0])
		{
			strcopy(SZF(szName), szSourceName);
		}
		else
		{
			GetClientName(iClient, SZF(szName));
		}

		if(szSourceGroup[0])
		{
			strcopy(SZF(szGroup), szSourceGroup);
		}
		else if(g_hFeatures[iClient])
		{
			g_hFeatures[iClient].GetString(KEY_GROUP, SZF(szGroup));

			if(!iClientID)
			{
				g_hFeatures[iClient].GetValue(KEY_CID, iClientID);
			}
		}
	}
	hDataPack.WriteCell(iClientID);
	hDataPack.WriteCell(GET_UID(iAdmin));
	hDataPack.WriteCell(bNotify);

	char szAdmin[PMP];
	switch(iAdmin)
	{
		case REASON_EXPIRED:
		{
			FormatEx(SZF(szAdmin), "%T", "REASON_EXPIRED", LANG_SERVER);
		}
		case REASON_OUTDATED:
		{
			FormatEx(SZF(szAdmin), "%T", "REASON_INACTIVITY", LANG_SERVER);
		}
		case REASON_PLUGIN:
		{
			FormatEx(SZF(szAdmin), "%T %s", "BY_PLUGIN", LANG_SERVER, szByWho);
		}
		case 0:
		{
			FormatEx(SZF(szAdmin), "%T", "BY_SERVER", LANG_SERVER);
		}
		default:
		{
			char szAdminInfo[128];
			UTIL_GetClientInfo(iAdmin, SZF(szAdminInfo));
			FormatEx(SZF(szAdmin), "%T %s", "BY_ADMIN", LANG_SERVER, szAdminInfo);
		}
	}

	hDataPack.WriteString(szAdmin);

	if(szName[0] && szGroup[0])
	{
		hDataPack.WriteString(szName);
		hDataPack.WriteString(szGroup);
		DB_RemoveClient(hDataPack, iClientID);
		return;
	}

	FormatEx(SZF(szQuery), "SELECT `name`, `group` FROM `vip_users` WHERE `account_id` = %d%s;", iClientID, g_szSID);

	DBG_SQL_Query(szQuery);
	g_hDatabase.Query(SQL_Callback_SelectRemoveClient, szQuery, hDataPack, DBPrio_Low);
}

public void SQL_Callback_SelectRemoveClient(Database hOwner, DBResultSet hResult, const char[] szError, DataPack hPack)
{
	DBG_SQL_Response("SQL_Callback_SelectRemoveClient");

	if (szError[0])
	{
		delete hPack;
		LogError("SQL_Callback_SelectRemoveClient: %s", szError);
		return;
	}

	if (hResult.FetchRow())
	{
		DBG_SQL_Response("hResult.FetchRow()");
		hPack.Reset();
		int iClientID = hPack.ReadCell();
		hPack.ReadCell();
		hPack.ReadCell();
		char szName[MAX_NAME_LENGTH*2+1];
		hPack.ReadString(SZF(szName));
		hResult.FetchString(0, SZF(szName));
		DBG_SQL_Response("hResult.FetchString(0) = '%s", szName);
		hPack.WriteString(szName);
		hResult.FetchString(1, SZF(szName));
		DBG_SQL_Response("hResult.FetchString(1) = '%s", szName);
		hPack.WriteString(szName);

		DB_RemoveClient(hPack, iClientID);
		return;
	}

	delete hPack;
}

void DB_RemoveClient(DataPack hDataPack, int iClientID)
{
	char szQuery[256];
	FormatEx(SZF(szQuery), "DELETE FROM `vip_users` WHERE `account_id` = %d%s;", iClientID, g_szSID);

	DBG_SQL_Query(szQuery);
	g_hDatabase.Query(SQL_Callback_RemoveClient, szQuery, hDataPack, DBPrio_Low);
}

public void SQL_Callback_RemoveClient(Database hOwner, DBResultSet hResult, const char[] szError, DataPack hPack)
{
	DBG_SQL_Response("SQL_Callback_SelectRemoveClient");

	if (szError[0])
	{
		delete hPack;
		LogError("SQL_Callback_RemoveClient: %s", szError);
		return;
	}

	DB_OnClientRemoved(hPack, hResult.AffectedRows);
}

void DB_OnClientRemoved(DataPack hPack, int iAffectedRows)
{
	DBG_SQL_Response("hResult.AffectedRows = %d", iAffectedRows);

	if (iAffectedRows)
	{
		hPack.Reset();

		int iClientID = hPack.ReadCell();
		int iAdmin = GET_CID(hPack.ReadCell());
		bool bNotify = view_as<bool>(hPack.ReadCell());
		char szAdmin[128], szName[MNL], szGroup[64];
		hPack.ReadString(SZF(szAdmin));
		hPack.ReadString(SZF(szName));
		hPack.ReadString(SZF(szGroup));

		// iAdmin is -1 when the admin left: still log and update the cache, only skip the reply
		if (g_CVAR_bLogsEnable)
		{
			LogToFile(g_szLogFile, "%T", "LOG_VIP_DELETED", LANG_SERVER, szName, iClientID, szGroup, szAdmin);
		}

		if (bNotify && iAdmin > 0)
		{
			ReplyToCommand(iAdmin, "%t", "ADMIN_VIP_PLAYER_DELETED", szName, iClientID);
		}

		// Remove from cache
		DB_RemoveVIPFromCache(iClientID);
	}

	delete hPack;
}

public void SQL_Callback_SelectExpiredAndOutdated(Database hOwner, DBResultSet hResult, const char[] szError, int iReason)
{
	DBG_SQL_Response("SQL_Callback_SelectExpiredAndOutdated");

	if (szError[0])
	{
		LogError("SQL_Callback_SelectExpiredAndOutdated: %s", szError);
		return;
	}

	DBG_SQL_Response("hResult.RowCount = %d", hResult.RowCount);

	if (hResult.RowCount)
	{
		// Delete every expired/outdated row in a single transaction instead of one query per row
		int iClientID;
		char szName[MNL*2], szGroup[64], szAdmin[PMP], szQuery[256];
		FormatEx(SZF(szAdmin), "%T", iReason == REASON_EXPIRED ? "REASON_EXPIRED":"REASON_INACTIVITY", LANG_SERVER);

		Transaction hTxn = new Transaction();
		while (hResult.FetchRow())
		{
			DBG_SQL_Response("hResult.FetchRow()");
			iClientID = hResult.FetchInt(0);
			DBG_SQL_Response("hResult.FetchInt(0) = %d", iClientID);
			hResult.FetchString(1, SZF(szName));
			DBG_SQL_Response("hResult.FetchString(1) = '%s'", szName);
			hResult.FetchString(2, SZF(szGroup));
			DBG_SQL_Response("hResult.FetchString(2) = '%s'", szGroup);

			// Same layout as the DataPack built by DB_RemoveClientFromID
			DataPack hPack = new DataPack();
			hPack.WriteCell(iClientID);
			hPack.WriteCell(iReason);
			hPack.WriteCell(false);
			hPack.WriteString(szAdmin);
			hPack.WriteString(szName);
			hPack.WriteString(szGroup);

			FormatEx(SZF(szQuery), "DELETE FROM `vip_users` WHERE `account_id` = %d%s;", iClientID, g_szSID);
			DBG_SQL_Query(szQuery);
			hTxn.AddQuery(szQuery, hPack);
		}

		g_hDatabase.Execute(hTxn, SQL_TxnCallback_RemoveClients, SQL_TxnCallback_RemoveClientsFailure, _, DBPrio_Low);
	}
}

public void SQL_TxnCallback_RemoveClients(Database hOwner, any data, int iNumQueries, DBResultSet[] hResults, any[] hQueryData)
{
	DBG_SQL_Response("SQL_TxnCallback_RemoveClients");

	for (int i = 0; i < iNumQueries; ++i)
	{
		DB_OnClientRemoved(view_as<DataPack>(hQueryData[i]), hResults[i].AffectedRows);
	}
}

public void SQL_TxnCallback_RemoveClientsFailure(Database hOwner, any data, int iNumQueries, const char[] szError, int iFailIndex, any[] hQueryData)
{
	LogError("SQL_TxnCallback_RemoveClientsFailure: %s", szError);

	for (int i = 0; i < iNumQueries; ++i)
	{
		DataPack hPack = view_as<DataPack>(hQueryData[i]);
		delete hPack;
	}
}

// VIP Cache Management Functions
void DB_LoadAllVIPsToCache()
{
	DBG_Database("DB_LoadAllVIPsToCache");

	if (!g_hDatabase)
	{
		LogError("Database not connected for VIP cache loading");
		return;
	}

	char szQuery[512];
	char szWhere[64];

	if (g_szSID[0])
	{
		#if USE_MORE_SERVERS
		if (g_CVAR_iServerID != 0)
		{
			FormatEx(SZF(szWhere), " AND (`sid` = %d OR `sid` = 0)", g_CVAR_iServerID);
		}
		else
		{
			FormatEx(SZF(szWhere), " AND `sid` = 0");
		}
		#endif
	}

	// Expired VIPs are not cached anyway, so do not fetch them
	FormatEx(SZF(szQuery), "SELECT `account_id`, `expires`, `group`, `name` FROM `vip_users` WHERE (`expires` = 0 OR `expires` > %d)%s;", GetTime(), szWhere);

	DBG_SQL_Query(szQuery);
	g_hDatabase.Query(SQL_Callback_LoadAllVIPsToCache, szQuery, _, DBPrio_High);
}

public void SQL_Callback_LoadAllVIPsToCache(Database hOwner, DBResultSet hResult, const char[] szError, any data)
{
	DBG_SQL_Response("SQL_Callback_LoadAllVIPsToCache");

	if (szError[0])
	{
		LogError("SQL_Callback_LoadAllVIPsToCache: %s", szError);
		return;
	}

	// Clear existing cache
	delete g_hVIPCache;
	g_hVIPCache = new StringMap();

	int iLoadedCount = 0;
	VIPCacheData vipData;

	int iCurrentTime = GetTime();
	while (hResult.FetchRow())
	{
		vipData.iAccountID = hResult.FetchInt(0);
		vipData.iExpires = hResult.FetchInt(1);
		hResult.FetchString(2, SZF(vipData.szGroup));
		hResult.FetchString(3, SZF(vipData.szName));

		// Only cache non-expired VIPs (expires = 0 means permanent)
		if (vipData.iExpires == 0 || vipData.iExpires > iCurrentTime)
		{
			char szKey[32];
			IntToString(vipData.iAccountID, SZF(szKey));
			g_hVIPCache.SetArray(szKey, vipData, sizeof(VIPCacheData));
			iLoadedCount++;
		}
	}

	LogMessage("VIP Cache loaded: %d VIP players cached", iLoadedCount);
}

public Action Timer_UpdateVIPCache(Handle hTimer)
{
	DB_LoadAllVIPsToCache();
	return Plugin_Continue;
}

bool DB_GetVIPFromCache(int iAccountID, VIPCacheData vipData)
{
	char szKey[32];
	IntToString(iAccountID, SZF(szKey));

	return g_hVIPCache.GetArray(szKey, vipData, sizeof(VIPCacheData));
}

void DB_UpdateVIPInCache(int iAccountID, int iExpires, const char[] szGroup, const char[] szName)
{
	char szKey[32];
	IntToString(iAccountID, SZF(szKey));

	VIPCacheData vipData;
	vipData.iAccountID = iAccountID;
	vipData.iExpires = iExpires;
	strcopy(SZF(vipData.szGroup), szGroup);
	strcopy(SZF(vipData.szName), szName);

	g_hVIPCache.SetArray(szKey, vipData, sizeof(VIPCacheData));
}

void DB_RemoveVIPFromCache(int iAccountID)
{
	char szKey[32];
	IntToString(iAccountID, SZF(szKey));
	g_hVIPCache.Remove(szKey);
}
