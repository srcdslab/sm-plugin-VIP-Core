# VIP Core - Copilot Development Instructions

## Repository Overview

This repository contains **VIP Core**, a comprehensive SourcePawn plugin for SourceMod that manages VIP status and privileges for players on Source engine game servers. The plugin features a modular architecture, multi-database support, and extensive customization options.

**Key Characteristics:**
- **Language**: SourcePawn (SourceMod scripting language)
- **Platform**: SourceMod 1.11.x - 1.12.x
- **Architecture**: Modular design with include-based structure
- **Database**: Dual support for MySQL and SQLite with async operations
- **Localization**: Multi-language support via translation files

## Project Structure

```
addons/sourcemod/
├── scripting/
│   ├── VIP_Core.sp              # Main plugin file (100 lines)
│   ├── include/vip_core.inc     # Public API definitions
│   └── vip/                     # Modular components
│       ├── API.sp               # Core API implementation (1315 lines)
│       ├── Database.sp          # Database operations (391 lines)
│       ├── Clients.sp           # Client management (576 lines)
│       ├── AdminMenu.sp         # Admin interface (659 lines)
│       ├── VipMenu.sp           # Player VIP menu (337 lines)
│       ├── Global.sp            # Global definitions & macros
│       ├── UTIL.sp              # Utility functions
│       ├── Features.sp          # Feature management
│       ├── Configs.sp           # Configuration handling
│       └── adminmenu/           # Admin menu sub-modules
├── data/vip/                    # Configuration files
│   ├── cfg/                     # INI configuration files
│   └── modules/                 # Module-specific configs
└── translations/                # Language files
    ├── vip_core.phrases.txt
    └── vip_modules.phrases.txt
```

## Development Environment

### Prerequisites
- SourceMod 1.11.x or 1.12.x development environment
- SourcePawn compiler (spcomp)
- Git for version control

### Build System
- **CI/CD**: GitHub Actions (`.github/workflows/build.yml`)
- **Dependency Management**: sourceknight.yaml
- **Compilation**: `spcomp VIP_Core.sp -E -o ../plugins/VIP_Core.smx -i./include`

### Local Development Setup
```bash
# Clone and enter directory
cd addons/sourcemod/scripting

# Compile main plugin
spcomp VIP_Core.sp -E -o ../plugins/VIP_Core.smx -i./include

# Verify compilation
ls -la ../plugins/VIP_Core.smx
```

## Coding Standards & Best Practices

### SourcePawn Conventions
```sourcepawn
#pragma semicolon 1
#pragma newdecls required

// Variable naming
int g_iGlobalVar;           // Global variables: g_ prefix + Hungarian notation
char g_szBuffer[256];       // Global strings: g_sz prefix
bool g_bIsEnabled;          // Global booleans: g_b prefix

// Function naming
void MyFunction()           // PascalCase for functions
int localVariable;          // camelCase for local variables
```

### Code Organization
- **Modular Design**: Each major functionality in separate .sp files under `vip/`
- **Include Structure**: Main plugin includes all modules via `#include "vip/ModuleName.sp"`
- **Global Definitions**: Centralized in `vip/Global.sp`
- **API Exposure**: Public functions and forwards in `include/vip_core.inc`

### Database Best Practices
```sourcepawn
// ALWAYS use async database operations
Database.Connect(OnDBConnect, "vip_core", 0);

// Use transactions for multiple operations
Transaction txn = new Transaction();
txn.AddQuery("INSERT ...", data);
g_hDatabase.Execute(txn, OnTransactionSuccess, OnTransactionFailed);

// Use methodmaps for database operations
DBResultSet results = view_as<DBResultSet>(hndl);
```

### Memory Management
```sourcepawn
// Use delete directly - no null checking needed
delete stringMap;
stringMap = new StringMap();

// Avoid .Clear() - creates memory leaks
// WRONG: arrayList.Clear();
// CORRECT: delete arrayList; arrayList = new ArrayList();
```

## Architecture Understanding

### Core Components

1. **VIP_Core.sp**: Entry point that includes all modules
2. **API.sp**: Core functionality, native functions, forwards
3. **Database.sp**: MySQL/SQLite operations with async pattern
4. **Clients.sp**: Player state management and VIP status
5. **Features.sp**: Modular feature system for extensibility
6. **AdminMenu.sp**: Administrative interface integration

### Feature System
The plugin uses a dynamic feature registration system:
```sourcepawn
// Register a new VIP feature
VIP_RegisterFeature("feature_name", VIP_BOOL, SELECTABLE, OnFeatureUsed);

// Feature callbacks
public Action OnFeatureUsed(int client, const char[] feature, VIP_ToggleState oldStatus, VIP_ToggleState &newStatus)
{
    // Handle feature activation/deactivation
    return Plugin_Continue;
}
```

### Database Schema
- **MySQL/SQLite**: Dual database support with charset `utf8mb4_unicode_ci`
- **Async Operations**: All database calls must be asynchronous
- **Connection Handling**: Automatic reconnection and error handling

## Common Development Tasks

### Adding New VIP Features
1. Create feature file in `vip/` directory
2. Register feature in `Features.sp` or module init
3. Implement callbacks for feature behavior
4. Add translations if user-facing
5. Update documentation

### Database Operations
```sourcepawn
// Query with prepared statements
char szQuery[512];
Format(szQuery, sizeof(szQuery), 
    "SELECT * FROM vip_users WHERE steamid = '%s'", steamId);
g_hDatabase.Query(OnQueryComplete, szQuery, GetClientUserId(client));

// Handle results
public void OnQueryComplete(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!client || error[0])
        return;
        
    while (results.FetchRow())
    {
        // Process row data
    }
}
```

### Menu Integration
```sourcepawn
// Add admin menu items
if (LibraryExists("adminmenu"))
{
    TopMenu adminMenu = GetAdminTopMenu();
    if (adminMenu != null)
    {
        adminMenu.AddItem("vip_manage", AdminMenu_VIP, ADMFLAG_ROOT);
    }
}
```

## Testing & Validation

### Pre-Commit Checks
1. **Compilation**: Ensure plugin compiles without warnings
2. **Syntax**: Follow SourcePawn syntax conventions
3. **Memory**: Check for potential memory leaks
4. **Database**: Validate all SQL queries are async and properly escaped

### Build Validation
```bash
# Test compilation for both SourceMod versions
spcomp VIP_Core.sp -E -o ../plugins/VIP_Core.smx -i./include

# Check for warnings or errors
echo $?  # Should be 0 for success
```

### Runtime Testing
- Deploy to test server with SourceMod
- Verify database connectivity (both MySQL and SQLite)
- Test VIP assignment and feature functionality
- Validate admin menu integration
- Check translation loading

## Configuration Files

### Key Configuration Files
- `data/vip/cfg/groups.ini`: VIP group definitions
- `data/vip/cfg/times.ini`: Time-based VIP configurations  
- `data/vip/cfg/info.ini`: Plugin information settings
- `data/vip/cfg/sort_menu.ini`: Menu sorting preferences

### Database Configuration
Plugin auto-detects database type:
- **MySQL**: Uses `databases.cfg` entry "vip_core"
- **SQLite**: Falls back to local SQLite database "vip_core"

## Performance Considerations

### Optimization Guidelines
- **Complexity**: Aim for O(1) operations over O(n) where possible
- **Timers**: Minimize timer usage; prefer event-driven programming
- **String Operations**: Cache results of expensive string operations
- **Database**: Use prepared statements and connection pooling
- **Memory**: Regular cleanup of temporary objects

### Server Impact
- Monitor server tick rate impact
- Profile memory usage in development
- Test with realistic player loads
- Optimize frequently called functions

## Troubleshooting

### Common Issues
1. **Compilation Errors**: Check include paths and SourceMod version compatibility
2. **Database Errors**: Verify connection string and async query usage  
3. **Memory Leaks**: Ensure proper cleanup with `delete` keyword
4. **Feature Registration**: Verify unique feature names and proper callbacks

### Debug Mode
Enable debug output by setting `DEBUG_MODE 1` in `VIP_Core.sp`:
```sourcepawn
#define DEBUG_MODE 1  // Enable debug messages
```

### Log Analysis
Check SourceMod logs for VIP Core messages:
```bash
tail -f logs/sourcemod/errors_*.log | grep -i vip
```

## Integration Points

### Admin Menu Integration
- Conditional compilation with `USE_ADMINMENU`
- Automatic integration when adminmenu library available
- Proper cleanup on library removal

### Client Preferences
- Uses SourceMod clientprefs for persistent settings
- Cookie-based storage for user preferences
- Automatic migration handling

### Translation System
- Support for multiple languages via `.phrases.txt` files
- Runtime language switching
- Fallback to English for missing translations

## Extension Development

### Creating VIP Modules
1. Create new `.sp` file in appropriate directory
2. Follow naming convention: `VIP_ModuleName.sp`
3. Include `vip_core` header
4. Register module features and callbacks
5. Handle cleanup in `OnPluginEnd()`

### API Usage
```sourcepawn
#include <vip_core>

public void OnPluginStart()
{
    // Wait for VIP Core to load
    if (VIP_IsVIPLoaded())
    {
        VIP_OnVIPLoaded();
    }
}

public void VIP_OnVIPLoaded()
{
    // Register features after VIP Core loads
    VIP_RegisterFeature("my_feature", VIP_BOOL, TOGGLABLE, OnMyFeature);
}
```

This instruction set provides comprehensive guidance for efficiently developing and maintaining the VIP Core plugin while following established patterns and best practices.