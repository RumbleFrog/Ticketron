#pragma semicolon 1

#define DEBUG

#define PLUGIN_AUTHOR "Fishy"
#define PLUGIN_VERSION "0.01"

#include <sourcemod>
#include <morecolors_store>
#include <EventLogs>
#undef REQUIRE_EXTENSIONS
#include <SteamWorks>


#pragma newdecls required

#define Divider_Left "▬▬ι═══════ﺤ(̲̅ ̲̅(̲̅"
#define Divider_Right ") ̲̅)-═══════ι▬▬";

#define Divider_Success "{grey}▬▬ι═══════ﺤ{lightseagreen}(̲̅ ̲̅(̲̅Success) ̲̅){grey}-═══════ι▬▬"
#define Divider_Failure "{grey}▬▬ι═══════ﺤ{lightseagreen}(̲̅ ̲̅(̲̅Failure) ̲̅){grey}-═══════ι▬▬"

//<!-- Main -->
Database hDB;

char g_cIP[64];
char g_cHostname[128];
char g_cBreed[32];

float g_fPollingRate = 10.0;

Handle g_hPollingTimer;

//<!--- ConVars --->
ConVar cPollingRate;
ConVar cBreed;

public Plugin myinfo = 
{
	name = "Ticketron",
	author = PLUGIN_AUTHOR,
	description = "A fully-featured ticket support system",
	version = PLUGIN_VERSION,
	url = "https://keybase.io/rumblefrog"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	hDB = SQL_Connect("ticketron", true, error, err_max);
	
	if (hDB == INVALID_HANDLE)
		return APLRes_Failure;
	
	//Tickets table must be created before others due to foreign key references	
	char TicketsCreateSQL[] = "CREATE TABLE IF NOT EXISTS `Ticketron_Tickets` ( `id` INT NOT NULL AUTO_INCREMENT , `host` VARBINARY(16) NOT NULL , `hostname` VARCHAR(64) NOT NULL , `breed` VARCHAR(32) NOT NULL , `target_name` VARCHAR(32) NULL DEFAULT NULL , `target_steamid` VARCHAR(32) NULL DEFAULT NULL , `target_ip` VARBINARY(16) NULL DEFAULT NULL, `reporter_name` VARCHAR(32) NOT NULL , `reporter_steamid` VARCHAR(32) NOT NULL , `reporter_ip` VARBINARY(16) NOT NULL, `reason` TEXT NOT NULL , `handler_name` VARCHAR(32) NULL DEFAULT NULL , `handler_steamid` VARCHAR(32) NULL DEFAULT NULL , `handled` TINYINT(1) NOT NULL DEFAULT '0' , `insignia` VARCHAR(32) NULL DEFAULT NULL , `time_reported` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP , `time_handled` TIMESTAMP NULL DEFAULT NULL , `time_closed` TIMESTAMP NULL DEFAULT NULL , `closed` TINYINT(1) NOT NULL DEFAULT '0' , PRIMARY KEY (`id`), INDEX (`breed`), INDEX (`handler_steamid`), INDEX (`handled`), INDEX (`target_steamid`), INDEX (`target_ip`), INDEX (`reporter_steamid`), INDEX (`reporter_ip`), INDEX (`insignia`), INDEX (`closed`)) ENGINE = InnoDB CHARSET=utf8mb4 COLLATE utf8mb4_general_ci";
	char RepliesCreateSQL[] = "CREATE TABLE IF NOT EXISTS `Ticketron_Replies` ( `id` INT NOT NULL AUTO_INCREMENT , `ticket_id` INT NOT NULL , `replier_name` VARCHAR(32) NOT NULL , `replier_steamid` VARCHAR(32) NOT NULL , `message` LONGTEXT NOT NULL , `time` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP , PRIMARY KEY (`id`), INDEX (`ticket_id`), INDEX (`replier_steamid`), FOREIGN KEY (`ticket_id`) REFERENCES `Ticketron_Tickets` (`id` )) ENGINE = InnoDB CHARSET=utf8mb4 COLLATE utf8mb4_general_ci";
	char NotificationsCreateSQL[] = "CREATE TABLE `Ticketron_Notifications` ( `id` INT NOT NULL AUTO_INCREMENT , `ticket_id` INT NOT NULL , `message` TEXT NOT NULL , `internal_handled` TINYINT(1) NOT NULL DEFAULT '0' , `external_handled` TINYINT(1) NOT NULL DEFAULT '0' , `time` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP , PRIMARY KEY (`id`), INDEX (`ticket_id`), INDEX (`internal_handled`), INDEX (`external_handled`), FOREIGN KEY (`ticket_id`) REFERENCES `Ticketron_Tickets` (`id` )) ENGINE = InnoDB CHARSET=utf8mb4 COLLATE utf8mb4_general_ci";
	
	SQL_SetCharset(hDB, "utf8mb4");
			
	SQL_TQuery(hDB, OnTableCreate, TicketsCreateSQL, DBPrio_High);
	SQL_TQuery(hDB, OnTableCreate, RepliesCreateSQL);
	SQL_TQuery(hDB, OnTableCreate, NotificationsCreateSQL);
	
	RegPluginLibrary("Ticketron");
	//TODO: Create Native
	//CreateNative("Ticketron_ReplyMessage", NativeLogPlugin);
	return APLRes_Success;
}

public void OnTableCreate(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == INVALID_HANDLE)
	{
		EL_LogPlugin(LOG_FATAL, "Unable to create table: %s", error);
		SetFailState("Unable to create table: %s", error);
	}
}

public void OnPluginStart()
{
	CreateConVar("sm_ticketron_version", PLUGIN_VERSION, "Ticketron Version", FCVAR_REPLICATED | FCVAR_SPONLY | FCVAR_DONTRECORD | FCVAR_NOTIFY);
	
	cPollingRate = CreateConVar("sm_ticketron_rate", "10", "Ticketron Notification Polling Rate", FCVAR_NONE, true, 1.0, false);
	cBreed = CreateConVar("sm_ticketron_breed", "global", "Ticketron External Breed Identifier", FCVAR_NONE);
	
	AutoExecConfig(true, "ticketron");
	
	RegAdminCmd("sm_ticket", CreateTicketCmd, 0, "Creates ticket");
	RegAdminCmd("sm_handle", HandleTicketCmd, ADMFLAG_GENERIC, "Handles ticket");
	RegAdminCmd("sm_unhandle", UnhandleTicketCmd, ADMFLAG_GENERIC, "Unhandles ticket");
	
	if (!SteamWorks_IsConnected())
	{
		int ip = GetConVarInt(FindConVar("hostip"));
		Format(g_cIP, sizeof(g_cIP), "%d.%d.%d.%d:%d", ((ip & 0xFF000000) >> 24) & 0xFF, ((ip & 0x00FF0000) >> 16) & 0xFF, ((ip & 0x0000FF00) >>  8) & 0xFF, ((ip & 0x000000FF) >>  0) & 0xFF, GetConVarInt(FindConVar("hostport")));
	}
	
	GetConVarString(FindConVar("hostname"), g_cHostname, sizeof g_cHostname);
	
	
	g_fPollingRate = cPollingRate.FloatValue;
	HookConVarChange(cPollingRate, OnConvarChanged);
	
	cBreed.GetString(g_cBreed, sizeof g_cBreed);
	HookConVarChange(cBreed, OnConvarChanged);
	
	g_hPollingTimer = CreateTimer(g_fPollingRate, PollingTimer, _, TIMER_REPEAT);
}

public Action CreateTicketCmd(int client, int args)
{
	char buffer[2048];
		
	ReplySource CmdOrigin = GetCmdReplySource();
	GetCmdArg(1, buffer, sizeof buffer);
	
	int buffer_len = strlen(buffer) * 2 + 1;
	
	char Client_Name[MAX_NAME_LENGTH], Client_SteamID64[32], Client_IP[45], Escaped_Name[128];
	char[] Escaped_Reason = new char[buffer_len];
	char[] InsertQuery = new char[1024 + buffer_len];
	
	GetClientName(client, Client_Name, sizeof Client_Name);
	GetClientAuthId(client, AuthId_SteamID64, Client_SteamID64, sizeof Client_SteamID64);
	GetClientIP(client, Client_IP, sizeof Client_IP);
	
	SQL_EscapeString(hDB, Client_Name, Escaped_Name, sizeof Escaped_Name);
	SQL_EscapeString(hDB, buffer, Escaped_Reason, buffer_len);
	
	Format(InsertQuery, 1024 + buffer_len, "INSERT INTO `Ticketron_Tickets` (`host`, `hostname`, `breed`, `reporter_name`, `reporter_steamid`, `reporter_ip`, `reason`) VALUES ('%s', '%s', '%s', '%s', '%s', '%s', '%s')", g_cIP, g_cHostname, g_cBreed, Escaped_Name, Client_SteamID64, Client_IP, Escaped_Reason);
	
	DataPack pData = CreateDataPack();
	WritePackCell(pData, CmdOrigin);
	WritePackCell(pData, client);
	
	hDB.Query(SQL_OnTicketCreate, InsertQuery, pData);
		
	return Plugin_Handled;
}

public void SQL_OnTicketCreate(Database db, DBResultSet results, const char[] error, any pData)
{
	ResetPack(pData);
	
	ReplySource CmdOrigin = ReadPackCell(pData);
	int client = ReadPackCell(pData);
	
	SetCmdReplySource(CmdOrigin);
	
	if (results == null)
	{
		int rid = EL_LogPlugin(LOG_ERROR, "Unable to insert row: %s", error);
		
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Error when creating the ticket. RID: {chartreuse}%i{grey}.", rid);
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	}
	
	int ticketid = results.InsertId;
	
	CReplyToCommand(client, "%s", Divider_Success);
	CReplyToCommand(client, "");
	CReplyToCommand(client, "{lightseagreen}Your Ticket ID: {chartreuse}%i{grey}.", ticketid);
	CReplyToCommand(client, "{lightseagreen}View Your Ticket Using {chartreuse}!ViewTicket #{grey}.");
	CReplyToCommand(client, "%s", Divider_Success);
	CReplyToCommand(client, "");
}

public Action HandleTicketCmd(int client, int args)
{
	ReplySource CmdOrigin = GetCmdReplySource();
	char buffer[16], Select_Query[256];
	int ticket;
	
	GetCmdArg(1, buffer, sizeof buffer);
	ticket = StringToInt(buffer);
	
	Format(Select_Query, sizeof Select_Query, "SELECT * FROM `Ticketron_Tickets` WHERE `id` = %i", ticket);
	
	DataPack pData = CreateDataPack();
	
	WritePackCell(pData, CmdOrigin);
	WritePackCell(pData, client);
	WritePackCell(pData, ticket);
	
	hDB.Query(SQL_OnTicketHandleSelect, Select_Query, pData);
	
	return Plugin_Handled;
}

public void SQL_OnTicketHandleSelect(Database db, DBResultSet results, const char[] error, any pData)
{
	ResetPack(pData);
	
	ReplySource CmdOrigin = ReadPackCell(pData);
	int client = ReadPackCell(pData);
	int ticket = ReadPackCell(pData);
	
	SetCmdReplySource(CmdOrigin);
	
	if (results == null)
	{
		int rid = EL_LogPlugin(LOG_ERROR, "Unable to select row: %s", error);
		
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Error when assigning the ticket. RID: {chartreuse}%i{grey}.", rid);
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	}
	
	results.FetchRow();
	
	if (results.FetchInt(13) == 1)
	{
		char Handler[MAX_NAME_LENGTH];
		results.FetchString(11, Handler, sizeof Handler);
		
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Ticket is currently being handled by {chartreuse}%s{grey}.", Handler);
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	}
	
	char UpdateQuery[512], Client_Name[MAX_NAME_LENGTH], Escaped_Name[128], Client_SteamID64[32];
	
	GetClientName(client, Client_Name, sizeof Client_Name);
	GetClientAuthId(client, AuthId_SteamID64, Client_SteamID64, sizeof Client_SteamID64);
	
	db.Escape(Client_Name, Escaped_Name, sizeof Escaped_Name);
	
	Format(UpdateQuery, sizeof UpdateQuery, "UPDATE `Ticketron_Tickets` SET `handler_name` = '%s', `handler_steamid` = '%s', `handled` = 1, `time_handled` = CURRENT_TIMESTAMP() WHERE `id` = '%i'", Escaped_Name, Client_SteamID64, ticket);
	
	db.Query(SQL_OnTicketHandleUpdate, UpdateQuery, pData);
}

public void SQL_OnTicketHandleUpdate(Database db, DBResultSet results, const char[] error, any pData)
{
	ResetPack(pData);
	
	ReplySource CmdOrigin = ReadPackCell(pData);
	int client = ReadPackCell(pData);
	int ticket = ReadPackCell(pData);
	
	SetCmdReplySource(CmdOrigin);
	
	if (results == null)
	{
		int rid = EL_LogPlugin(LOG_ERROR, "Unable to insert row: %s", error);
		
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Error when assigning the ticket. RID: {chartreuse}%i{grey}.", rid);
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	}
	
	CReplyToCommand(client, "%s", Divider_Success);
	CReplyToCommand(client, "");
	CReplyToCommand(client, "{lightseagreen}Now Handling Ticket ID: {chartreuse}%i{grey}.", ticket);
	CReplyToCommand(client, "{lightseagreen}Unhandle The Ticket Using {chartreuse}!UnhandleTicket #{grey}.");
	CReplyToCommand(client, "{lightseagreen}View The Ticket Using {chartreuse}!ViewTicket #{grey}.");
	CReplyToCommand(client, "%s", Divider_Success);
	CReplyToCommand(client, "");
}

public Action UnhandleTicketCmd(int client, int args)
{
	ReplySource CmdOrigin = GetCmdReplySource();
	char buffer[16], Select_Query[256], Client_SteamID64[32];
	int ticket;
	
	GetCmdArg(1, buffer, sizeof buffer);
	GetClientAuthId(client, AuthId_SteamID64, Client_SteamID64, sizeof Client_SteamID64);
	ticket = StringToInt(buffer);
	
	Format(Select_Query, sizeof Select_Query, "SELECT * FROM `Ticketron_Tickets` WHERE `id` = %i AND `handler_steamid` = '%s' AND `handled` = 1", ticket, Client_SteamID64);
	
	DataPack pData = CreateDataPack();
	
	WritePackCell(pData, CmdOrigin);
	WritePackCell(pData, client);
	WritePackCell(pData, ticket);
	
	hDB.Query(SQL_OnTicketUnhandleSelect, Select_Query, pData);
	
	return Plugin_Handled;
}

public void SQL_OnTicketUnhandleSelect(Database db, DBResultSet results, const char[] error, any pData)
{
	ResetPack(pData);
	
	ReplySource CmdOrigin = ReadPackCell(pData);
	int client = ReadPackCell(pData);
	int ticket = ReadPackCell(pData);
	
	SetCmdReplySource(CmdOrigin);
	
	if (results == null)
	{
		int rid = EL_LogPlugin(LOG_ERROR, "Unable to insert row: %s", error);
		
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Error when authorizing the action. RID: {chartreuse}%i{grey}.", rid);
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	} else if (results.RowCount == 0)
	{
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Insufficient permission while attempting to unhandle.");
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	}
	
	char UpdateQuery[512];
	
	Format(UpdateQuery, sizeof UpdateQuery, "UPDATE `Ticketron_Tickets` SET `handler_name` = NULL, `handler_steamid` = NULL, `handled` = 0, `time_handled` = NULL WHERE `id` = '%i'", ticket);
	
	db.Query(SQL_OnTicketUnhandleUpdate, UpdateQuery, pData);
}

public void SQL_OnTicketUnhandleUpdate(Database db, DBResultSet results, const char[] error, any pData)
{
	ResetPack(pData);
	
	ReplySource CmdOrigin = ReadPackCell(pData);
	int client = ReadPackCell(pData);
	int ticket = ReadPackCell(pData);
	
	SetCmdReplySource(CmdOrigin);
	
	if (results == null)
	{
		int rid = EL_LogPlugin(LOG_ERROR, "Unable to insert row: %s", error);
		
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		CReplyToCommand(client, "{lightseagreen}Error when unassigning the ticket. RID: {chartreuse}%i{grey}.", rid);
		CReplyToCommand(client, "%s", Divider_Failure);
		CReplyToCommand(client, "");
		
		return;
	}
	
	CReplyToCommand(client, "%s", Divider_Success);
	CReplyToCommand(client, "");
	CReplyToCommand(client, "{lightseagreen}Now Unhandled Ticket ID: {chartreuse}%i{grey}.", ticket);
	CReplyToCommand(client, "%s", Divider_Success);
	CReplyToCommand(client, "");
}

public Action PollingTimer(Handle timer)
{
	char SelectQuery[512];
	
	Format(SelectQuery, sizeof SelectQuery, "SELECT n.`*`, t.`reporter_steamid` FROM `Ticketron_Notifications` n INNER JOIN `Ticketron_Tickets` t ON t.`id` = n.`ticket_id`");
	
	hDB.Query(SQL_OnPollingTimerSelect, SelectQuery);
}

public void SQL_OnPollingTimerSelect(Database db, DBResultSet results, const char[] error, any pData)
{
	//Not going to log because it'd flood the database due to a repeated action
	
	if (results == null)
		return;
	
	int NID;
	int Ticket;
	char Message[256], Client_SteamID64[32], Search_SteamID64[32], UpdateQuery[256];

	while(results.FetchRow())
	{
		NID = results.FetchInt(0);
		Ticket = results.FetchInt(1);
		results.FetchString(2, Message, sizeof Message);
		results.FetchString(6, Client_SteamID64, sizeof Client_SteamID64);
		
		for (int i = 1; i <= MaxClients; i++)
		{
			if(Client_IsValid(i))
			{
				GetClientAuthId(i, AuthId_SteamID64, Search_SteamID64, sizeof Search_SteamID64);
				
				if (StrEqual(Client_SteamID64, Search_SteamID64, false))
				{
					MoreColors_CPrintToChat(i, "{lightseagreen}Ticket #%i: {grey}%s", Ticket, Message);
					
					Format(UpdateQuery, sizeof UpdateQuery, "UPDATE `Ticketron_Notifications` SET `internal_handled` = 1 WHERE `id` = '%i'", NID);
					db.Query(SQL_OnPollingTimerUpdate, UpdateQuery);
				}
			}
		}
	}
}

public void SQL_OnPollingTimerUpdate(Database db, DBResultSet results, const char[] error, any pData)
{
	//Not worrying about the result
}

public void OnConvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == cPollingRate)
	{
		g_fPollingRate = cPollingRate.FloatValue;
		KillTimer(g_hPollingTimer);
		g_hPollingTimer = CreateTimer(g_fPollingRate, PollingTimer, _, TIMER_REPEAT);
	}
	if (convar == cBreed)
		cBreed.GetString(g_cBreed, sizeof g_cBreed);
}

public int SteamWorks_SteamServersConnected()
{
	int octets[4];
	SteamWorks_GetPublicIP(octets);
	Format(g_cIP, sizeof(g_cIP), "%d.%d.%d.%d:%d", octets[0], octets[1], octets[2], octets[3], GetConVarInt(FindConVar("hostport")));
}

stock bool Client_IsValid(int client, bool checkConnected=true)
{
	if (client > 4096) {
		client = EntRefToEntIndex(client);
	}

	if (client < 1 || client > MaxClients) {
		return false;
	}

	if (checkConnected && !IsClientConnected(client)) {
		return false;
	}

	return true;
}