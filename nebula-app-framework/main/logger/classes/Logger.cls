/*************************************************************************************************
* This file is part of the Nebula Logger project, released under the MIT License.                *
* See LICENSE file or go to https://github.com/jongpie/NebulaLogger for full license details.    *
*************************************************************************************************/
public without sharing class Logger {

    private static final String TRANSACTION_ID              = new Uuid().getValue();
    private static final List<LogEntryEvent__e> LOG_ENTRIES = new List<LogEntryEvent__e>();
    private static final User CURRENT_USER                  = [SELECT Id, Profile.Name, UserRole.Name FROM User WHERE Id = :UserInfo.getUserId()];

    private static Boolean suspendSaving = false;

    public static String getTransactionId() {
        return TRANSACTION_ID;
    }

    public static void suspendSaving() {
        suspendSaving = true;
    }

    public static void resumeSaving() {
        suspendSaving = false;
    }

    public static void flushBuffer() {
        LOG_ENTRIES.clear();
    }

    public static String addDebugEntry(String message) {
        return addDebugEntry(LoggingLevel.DEBUG, message);
    }

    public static String addDebugEntry(LoggingLevel loggingLevel, String message) {
        return addDebugEntry(loggingLevel, message, null);
    }

    public static String addDebugEntry(LoggingLevel loggingLevel, String message, List<String> topics) {
        return addEntry(loggingLevel, null, message, null, 'Apex', getOriginLocation(), topics, null);
    }

    public static String addExceptionEntry(Exception ex) {
        return addExceptionEntry(ex, null);
    }

    public static String addExceptionEntry(Exception ex, List<String> topics) {
        return addEntry(LoggingLevel.ERROR, null, ex.getMessage(), ex, 'Apex', getOriginLocation(), topics, null);
    }

    public static String addRecordDebugEntry(SObject record, String message) {
        return addRecordDebugEntry(LoggingLevel.DEBUG, record, message);
    }

    public static String addRecordDebugEntry(LoggingLevel loggingLevel, SObject record, String message) {
        return addRecordDebugEntry(loggingLevel, record, message, null);
    }

    public static String addRecordDebugEntry(LoggingLevel loggingLevel, SObject record, String message, List<String> topics) {
        return addEntry(loggingLevel, record, message, null, 'Apex', getOriginLocation(), topics, null);
    }

    public static String addRecordExceptionEntry(SObject record, Exception ex) {
        return addRecordExceptionEntry(record, ex, null);
    }

    public static String addRecordExceptionEntry(SObject record, Exception ex, List<String> topics) {
        return addEntry(LoggingLevel.ERROR, record, ex.getMessage(), ex, 'Apex', getOriginLocation(), topics, null);
    }

    public static void addFlowEntries(List<FlowLogEntry> flowLogEntries) {
        Boolean saveLog = false;
        for(FlowLogEntry flowLogEntry : flowLogEntries) {
            LoggingLevel loggingLevel;
            if(!String.isBlank(flowLogEntry.LoggingLevelName)) loggingLevel = getLoggingLevel(flowLogEntry.LoggingLevelName);

            if(flowLogEntry.saveLog) saveLog = true;

            SObject record = flowLogEntry.recordId == null ? null : flowLogEntry.recordId.getSObjectType().newSObject(flowLogEntry.recordId);

            addEntry(loggingLevel, record, flowLogEntry.message, null, 'Process Builder/Flow', flowLogEntry.flowName, flowLogEntry.topics, null);
        }
        if(saveLog) saveLog();
    }

    @AuraEnabled
    public static void saveLightningEntries(String logEntriesJson) {
        List<LightningLogEntry> lightningLogEntries = (List<LightningLogEntry>)Json.deserialize(logEntriesJson, List<LightningLogEntry>.class);
        for(LightningLogEntry logEntry : lightningLogEntries) {
            LoggingLevel logLevel;
            if(!String.isBlank(logEntry.loggingLevelName)) logLevel = getLoggingLevel(logEntry.loggingLevelName);
            if(logEntry.error != null) logLevel = LoggingLevel.ERROR;

            addEntry(logLevel, null, logEntry.message, null, 'Lightning Component', logEntry.originLocation, logEntry.topics, logEntry);
        }
        saveLog();
    }

    @InvocableMethod(label='Save Log' description='Saves any log entries that have been generated')
    public static void saveLog() {
        saveLog(false);
    }

    public static String saveLog(Boolean saveLogViaRestApi) {
        if(LOG_ENTRIES.isEmpty()) return getTransactionId();

        String originLocation = 'Logger.saveLog';
        if(suspendSaving) {
            String suspendSavingLogMessage = 'Logging suspended, ignoring call to saveLog()';

            addEntry(LoggingLevel.FINEST, null, suspendSavingLogMessage, null, 'Apex', originLocation, null, null);

            return getTransactionId();
        }

        String savingLogMessage = 'Saving ' + LOG_ENTRIES.size() + ' log entries';
        if(saveLogViaRestApi) savingLogMessage += ' via REST API';

        addEntry(LoggingLevel.FINEST, null, savingLogMessage, null, 'Apex', originLocation, null, null);

        if(saveLogViaRestApi) RestApi.insertRecords(LOG_ENTRIES);
        else EventBus.publish(LOG_ENTRIES);

        LOG_ENTRIES.clear();

        return getTransactionId();
    }

    public static LoggingLevel getLoggingLevel(String loggingLevelName) {
        if(loggingLevelName != null) loggingLevelName = loggingLevelName.toUpperCase();

        switch on loggingLevelName {
            when 'NONE'   { return LoggingLevel.NONE;   }
            when 'ERROR'  { return LoggingLevel.ERROR;  }
            when 'WARN'   { return LoggingLevel.WARN;   }
            when 'INFO'   { return LoggingLevel.INFO;   }
            when 'DEBUG'  { return LoggingLevel.DEBUG;  }
            when 'FINE'   { return LoggingLevel.FINE;   }
            when 'FINER'  { return LoggingLevel.FINER;  }
            when 'FINEST' { return LoggingLevel.FINEST; }
            when else     { return LoggingLevel.DEBUG;  }
        }
    }

    private static LoggerSettings__c getSettings() {
        return LoggerSettings__c.getInstance();
    }

    private static String getOriginLocation() {
        String originLocation;
        for(String currentStackTraceLine : new DmlException().getStackTraceString().split('\n')) {
            if(currentStackTraceLine.contains('.Logger.')) continue;

            originLocation = currentStackTraceLine.substringBefore(':');
            if(originLocation.startsWith('Class.')) {
                originLocation = originLocation.substringAfter('Class.');
            }
            break;
        }

        return originLocation;
    }

    private static LoggingLevel getUserLoggingLevel() {
        return getLoggingLevel(getSettings().LoggingLevel__c);
    }

    private static Boolean meetsUserLoggingLevel(LoggingLevel userLoggingLevel, LoggingLevel logEntryLoggingLevel) {
        return userLoggingLevel.ordinal() <= logEntryLoggingLevel.ordinal();
    }

    private static String truncateFieldValue(Schema.SObjectField field, String value) {
        Integer fieldMaxLength = field.getDescribe().getLength();
        if(String.isEmpty(value)) return value;
        else if(value.length() <= fieldMaxLength) return value;
        else return value.left(fieldMaxLength);
    }

    private static String getExceptionStackTrace(Exception ex, LightningLogEntry lightningLogEntry) {
        if(ex != null) return ex.getStackTraceString();
        else if(lightningLogEntry != null && lightningLogEntry.error != null) return lightningLogEntry.error.stack;
        else return null;
    }

    private static String getExceptionType(Exception ex, LightningLogEntry lightningLogEntry) {
        if(ex != null) return ex.getTypeName();
        else if(lightningLogEntry != null && lightningLogEntry.error != null) return 'LightningError';
        else return null;
    }

    private static String addEntry(LoggingLevel logEntryLoggingLevel, SObject record, String message, Exception ex, String originType, String originLocation, List<String> topics, LightningLogEntry lightningLogEntry) {
        Datetime logEntryTimestamp = lightningLogEntry == null ? System.now() : lightningLogEntry.timestamp;

        if(logEntryLoggingLevel == null) logEntryLoggingLevel = LoggingLevel.DEBUG;
        if(ex != null) message = ex.getMessage();
        if(lightningLogEntry != null && lightningLogEntry.error != null) message = lightningLogEntry.error.message;

        if(getSettings().GenerateDebugStatements__c) System.debug(logEntryLoggingLevel, message);
        if(!meetsUserLoggingLevel(getUserLoggingLevel(), logEntryLoggingLevel)) return null;

        String type = 'Debug';
        if(ex != null) type = 'Exception';
        if(lightningLogEntry != null && lightningLogEntry.error != null) type = 'Exception';

        if(type == 'Debug' && !getSettings().StoreDebugLogEntries__c) return null;
        if(type == 'Exception' && !getSettings().StoreExceptionLogEntries__c) return null;

        String truncatedMessage = truncateFieldValue(Schema.LogEntryEvent__e.Message__c, message);
        Boolean messageTruncated = message != truncatedMessage;

        String visualforcePageName = ApexPages.currentPage() == null ? null : ApexPages.currentPage().getUrl();
        if(visualforcePageName != null && visualforcePageName.contains('?')) visualforcePageName = visualforcePageName.substringBetween('apex/', '?');
        else if(visualforcePageName != null) visualforcePageName = visualforcePageName.substringAfter('apex/');

        Map<String, String> sessionMap = Test.isRunningTest() ? null : Auth.SessionManagement.getCurrentSession();

        LogEntryEvent__e platformLogEntry = new LogEntryEvent__e(
            ContextIsApexRest__c              = RestContext.request != null,
            ContextIsBatch__c                 = System.isBatch(),
            ContextIsFuture__c                = System.isFuture(),
            ContextIsLightningComponent__c    = lightningLogEntry != null,
            ContextIsQueueable__c             = System.isQueueable(),
            ContextIsScheduledJob__c          = System.isScheduled(),
            ContextIsTriggerExecuting__c      = Trigger.isExecuting,
            ContextIsVisualforce__c           = ApexPages.currentPage() != null,
            ContextLightningComponentName__c  = lightningLogEntry == null ? null : lightningLogEntry.componentName,
            ContextThemeDisplayed__c          = UserInfo.getUiThemeDisplayed(),
            ContextTriggerOperationType__c    = Trigger.operationType == null ? null : Trigger.operationType.name(),
            ContextTriggerSObjectType__c      = Trigger.new == null ? null : String.valueOf(Trigger.new.getSObjectType()),
            ContextVisualforcePage__c         = visualforcePageName,
            ExceptionStackTrace__c            = truncateFieldValue(Schema.LogEntryEvent__e.ExceptionStackTrace__c, getExceptionStackTrace(ex, lightningLogEntry)),
            ExceptionType__c                  = truncateFieldValue(Schema.LogEntryEvent__e.ExceptionType__c, getExceptionType(ex, lightningLogEntry)),
            LimitsAggregateQueriesMax__c      = Limits.getLimitAggregateQueries(),
            LimitsAggregateQueriesUsed__c     = Limits.getAggregateQueries(),
            LimitsAsyncCallsMax__c            = Limits.getLimitAsyncCalls(),
            LimitsAsyncCallsUsed__c           = Limits.getAsyncCalls(),
            LimitsCalloutsMax__c              = Limits.getLimitCallouts(),
            LimitsCalloutsUsed__c             = Limits.getCallouts(),
            LimitsCpuTimeMax__c               = Limits.getLimitCpuTime(),
            LimitsCpuTimeUsed__c              = Limits.getCpuTime(),
            LimitsDmlRowsMax__c               = Limits.getLimitDmlRows(),
            LimitsDmlRowsUsed__c              = Limits.getDmlRows(),
            LimitsDmlStatementsMax__c         = Limits.getLimitDmlStatements(),
            LimitsDmlStatementsUsed__c        = Limits.getDmlStatements(),
            LimitsEmailInvocationsMax__c      = Limits.getLimitEmailInvocations(),
            LimitsEmailInvocationsUsed__c     = Limits.getEmailInvocations(),
            LimitsFutureCallsMax__c           = Limits.getLimitFutureCalls(),
            LimitsFutureCallsUsed__c          = Limits.getFutureCalls(),
            LimitsHeapSizeMax__c              = Limits.getLimitHeapSize(),
            LimitsHeapSizeUsed__c             = Limits.getHeapSize(),
            LimitsMobilePushApexCallsMax__c   = Limits.getLimitMobilePushApexCalls(),
            LimitsMobilePushApexCallsUsed__c  = Limits.getMobilePushApexCalls(),
            LimitsQueueableJobsMax__c         = Limits.getLimitQueueableJobs(),
            LimitsQueueableJobsUsed__c        = Limits.getQueueableJobs(),
            LimitsSoqlQueriesMax__c           = Limits.getLimitQueries(),
            LimitsSoqlQueriesUsed__c          = Limits.getQueries(),
            LimitsSoqlQueryLocatorRowsMax__c  = Limits.getLimitQueryLocatorRows(),
            LimitsSoqlQueryLocatorRowsUsed__c = Limits.getQueryLocatorRows(),
            LimitsSoqlQueryRowsMax__c         = Limits.getLimitQueryRows(),
            LimitsSoqlQueryRowsUsed__c        = Limits.getQueryRows(),
            LimitsSoslSearchesMax__c          = Limits.getLimitSoslQueries(),
            LimitsSoslSearchesUsed__c         = Limits.getSoslQueries(),
            Locale__c                         = UserInfo.getLocale(),
            LoggingLevel__c                   = logEntryLoggingLevel.name(),
            LoggingLevelOrdinal__c            = logEntryLoggingLevel.ordinal(),
            LoginDomain__c                    = sessionMap == null ? null : sessionMap.get('LoginDomain'),
            LoginHistoryId__c                 = sessionMap == null ? null : sessionMap.get('LoginHistoryId'),
            LoginType__c                      = sessionMap == null ? null : sessionMap.get('LoginType'),
            LogoutUrl__c                      = sessionMap == null ? null : sessionMap.get('LogoutUrl'),
            Message__c                        = truncatedMessage == null ? null : String.escapeSingleQuotes(truncatedMessage),
            MessageTruncated__c               = messageTruncated,
            OriginLocation__c                 = truncateFieldValue(Schema.LogEntryEvent__e.OriginLocation__c, originLocation),
            OriginType__c                     = originType,
            ProfileId__c                      = UserInfo.getProfileId(),
            ProfileName__c                    = CURRENT_USER.Profile.Name,
            RelatedRecordId__c                = record != null && record.Id != null ? record.Id : null,
            SessionId__c                      = sessionMap == null ? null : sessionMap.get('SessionId'),
            SessionSecurityLevel__c           = sessionMap == null ? null : sessionMap.get('SessionSecurityLevel'),
            SessionType__c                    = sessionMap == null ? null : sessionMap.get('SessionType'),
            SourceIp__c                       = sessionMap == null ? null : sessionMap.get('SourceIp'),
            Timestamp__c                      = logEntryTimestamp,
            TimeZoneId__c                     = UserInfo.getTimeZone().getId(),
            TimeZoneName__c                   = UserInfo.getTimeZone().getDisplayName(),
            Topics__c                         = topics == null ? null : String.escapeSingleQuotes(String.join(topics, ',')),
            TransactionEntryId__c             = new Uuid().getValue(),
            TransactionId__c                  = TRANSACTION_ID,
            Type__c                           = type,
            UserLoggingLevel__c               = getUserLoggingLevel().name(),
            UserLoggingLevelOrdinal__c        = getUserLoggingLevel().ordinal(),
            UserRoleId__c                     = UserInfo.getUserRoleId(),
            UserRoleName__c                   = CURRENT_USER.UserRole.Name,
            UserType__c                       = UserInfo.getUserType()
        );
        LOG_ENTRIES.add(platformLogEntry);

        if(ex != null && getSettings().AutoSaveExceptionEntries__c) saveLog();

        return platformLogEntry.TransactionEntryId__c;
    }

}