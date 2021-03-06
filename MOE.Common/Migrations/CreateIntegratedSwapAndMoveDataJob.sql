--USE [msdb]
--GO
DECLARE @jobId BINARY(16)
EXEC  msdb.dbo.sp_add_job @job_name=N'Reclaim File Space', 
		@enabled=1, 
		@notify_level_eventlog=2, 
		@notify_level_email=2, 
		@notify_level_page=2, 
		@delete_level=0, 
		@description=N'This job reclaims file space by swapping out a partitioned table, keeping the signal information for the signals in the main table as listed in the table, [DatabaseArchiveExcludedSignals].  It gets additional information from the table, [ApplicationSettings].', 
		@category_name=N'Database Maintenance', 
		@owner_login_name=N'UTAH\asanchez', @job_id = @jobId OUTPUT
select @jobId
--GO
EXEC msdb.dbo.sp_add_jobserver @job_name=N'Reclaim File Space', @server_name = N'SRWTCNS54'
--GO
--USE [msdb]
--GO
EXEC msdb.dbo.sp_add_jobstep @job_name=N'Reclaim File Space', @step_name=N'ReClaim FIleSpace', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_fail_action=2, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'
DECLARE @CHK_Constrants  varchar(100)

--DECLARE @ControllerObjectName varchar(200)

Declare @Counter		 int
DECLARE @CurrentMonth    int
DECLARE @CurrentTime     datetime2(7)
DECLARE @CurrentYear     int
DECLARE @dataSpaceId1    int
DECLARE @dataSpaceId2    int
DECLARE @Dummy			 int
DECLARE @EndMonth        int
DECLARE @EndTime         datetime2(7)
DECLARE @EndYear         int
Declare @FileGroupName1  varchar(100)
Declare @FileGroupName2  varchar(100)
DECLARE @fileSize		 int
DECLARE @fileSizeCurrent int
DECLARE @fileSizeGrowth  int
DECLARE @fileSizeUsed    int
DECLARE @FileSpaceUsed   int
DECLARE @FindPartitionNumber varchar(200)
DECLARE @FirstIndexDeleteController varchar(1000)
DECLARE @FirstIndexDeleteSpeed varchar(1000)
DECLARE @FirstIndexNameController  varchar(1000)
DECLARE @FirstIndexNameSpeed  varchar(1000)
-- DECLARE @GenericIndexName varchar(200) 
DECLARE @IndexName       varchar(2000)
DECLARE @IndexTableName  varchar(200)
--DECLARE @LowerBoundary1   varchar(100)
--DECLARE @LowerBoundary2   varchar(100)
DECLARE @MonthCounter     int
DECLARE @MonthsToKeepData int
DECLARE @MonthsToKeepIndex  int
DECLARE @newFileSize      int
DECLARE @NeedToCompress   int
DECLARE @NeedToShrink     int
DECLARE @PartitionNumber  int
DECLARE @SecondIndexDeleteController varchar(1000)
DECLARE @SecondIndexDeleteSpeed varchar(1000)
DECLARE @SecondIndexNameController varchar(1000)
DECLARE @SecondIndexNameSpeed varchar(1000)
DECLARE @SelectedDeleteOrMove    int  -- 1 Delete, 2 Move, NULL -> Set value to 0
DECLARE @SQLSTATEMENT     nvarchar(4000)
DECLARE @StartMonth       int
DECLARE @StartTime        datetime2(7)
DECLARE @StartYear        int
DECLARE @StopDropingTable int
DECLARE @StopValue        int
DECLARE @TableCompression tinyint
DECLARE @TableCompressionType varchar(10)
DECLARE @TableCounter     smallint
DECLARE @TableHasIndexRemoved1 bit
DECLARE @TableHasIndexRemoved2 bit
DECLARE @TableHasSwappedTableRemoved bit
DECLARE @TableLoopCounter smallint
DECLARE @TableName1       varchar(40)
DECLARE @TableName2       varchar(40)
DECLARE @TableNameInCatalog varchar(40)
DECLARE @TableNumber      smallint
DECLARE @Tens             varchar(1)
DECLARE @StaggingTable1   varchar(200)
DECLARE @StaggingTable2   varchar(200)
DECLARE @ThirdIndexDeleteSpeed varchar(1000)
DECLARE @ThirdIndexNameSpeed varchar(1000)
--DECLARE @UpperBoundary1   varchar(100)
--DECLARE @UpperBoundary2   varchar(100)
DECLARE @UpperBoundaryMonth int
DECLARE @UpperBoundaryYear  int
DECLARE @UpperTens          varchar(1)
DECLARE @Verbose            int

Set @Verbose = 0


-- Can get these names from the Select with all of the joins, but need to isolate them out.
-- Note need to have the system show the index name , the elements of the index and how many.
-- But for now we will find them from the Object Explorer

SET @FirstIndexNameController  = ''IX_Clustered_Controller_Event_Log_Temp''
SET @SecondIndexNameController = ''IX_Controller_Event_Log''

SET @FirstIndexNameSpeed = ''IX_Clustered_Speed_Events''
SET @SecondIndexNameSpeed = ''IX_ByDetID''
SET @ThirdIndexNameSpeed = ''ByTimestampByDetID''

Select @CurrentTime = getdate ()

Set @CurrentYear = year(getdate())
Set @CurrentMonth = month(getdate())

-- Get the application settings
Select  
	@MonthsToKeepIndex = [MonthsToKeepIndex]
	,@MonthsToKeepData = [MonthsToKeepData]
	,@SelectedDeleteOrMove = [SelectedDeleteOrMove] 
FROM [dbo].[ApplicationSettings]
Where ApplicationId = 3

IF (@MonthsToKeepData IS NULL)
	SET @MonthsToKeepData = 120  -- 10 years as a default
IF (@MonthsToKeepIndex IS NULL) 
	SET @MonthsToKeepIndex = 120 -- 10 years as a default
IF (@SelectedDeleteOrMove IS NULL) 
	SET @SelectedDeleteOrMove = 0 -- 0 Do Nothing, 1 is Delete, 2 is move

IF (@Verbose = 1)
	select @CurrentTime CurrentTime	, @CurrentYear CurrentYear, @SelectedDeleteOrMove DeleteOrMove, 
		@CurrentMonth CurrentMonth , @MonthsToKeepData KeepDataMonths ,@MonthsToKeepIndex KeepMonthsIndex

SET @TableLoopCounter = 1


-- Now to get the starting point. OK. Start time is the oldest time.
SELECT @StartTime = Min ([Timestamp])
  FROM [dbo].[Controller_Event_Log]

Set @StartYear = year(@StartTime)
Set @StartMonth = month(@StartTime)

-- The End point is the current time minus the number of months to keep.
set @EndMonth = @CurrentMonth - @MonthsToKeepIndex
set @EndYear = @CurrentYear

While (@EndMonth < 0) BEGIN
	SET @EndYear = @EndYear - 1
	SET @EndMonth = @EndMonth + 12
END

-- Lets figure out how many times through the loop with the values we have
SET @StopValue = (@CurrentYear - @StartYear)*12 - @StartMonth - @MonthsToKeepIndex + @CurrentMonth 
SET @Counter = 1

SET @StopDropingTable = (@CurrentYear - @StartYear)*12 - @StartMonth - @MonthsToKeepdata + @CurrentMonth 

-- Now to Swap out partitions for the given months for each table 
While (@Counter <= @StopValue)  BEGIN
	SET @NeedToCompress = 0
	SET @NeedToShrink   = 0
	-- Do a dance for the StartMonth
	IF (@StartMonth < 10)
		SET @tens = ''0''
	ELSE
		SET @tens = ''''
	Set @UpperBoundaryYear = @StartYear 
	Set @UpperBoundaryMonth = @StartMonth +1
	--Same Dance for the Upper Boundary
	IF (@UpperBoundaryMonth  >12) BEGIN
		-- Opps, Mickey''s Calendar is broken.  No 13 months in a year, next year please!
	   SET @UpperBoundaryYear = @UpperBoundaryYear + 1
	   SET @UpperBoundaryMonth = 1
	 End  
	IF (@UpperBoundaryMonth < 10) 
		SET @UpperTens  = ''0''
    ELSE
	    SET @UpperTens = ''''
	SET @TableName1 = ''Controller_Event_Log''
	SET @TableName2 = ''Speed_Events''
	-- Find the Partition details for a month
	Set @FindPartitionNumber = CAST (@StartYear AS nvarchar (4)) +''-'' + @tens 
	        + CAST (@StartMonth AS nvarchar (2)) +''-15''	
	IF (@Verbose = 1)
		SELECT @FindPartitionNumber PartitionDate
	set @PartitionNumber = $PARTITION.[PF_MOEPARTITION_Month](@FindPartitionNumber)
    SET @StaggingTable1 = ''Stagging_'' + @TableName1 + ''_Part-''  + CAST (@PartitionNumber AS nvarchar(4))
		+ ''-'' + CAST (@StartYear AS nvarchar (4)) + ''-'' +@tens +  CAST (@StartMonth AS nvarchar (2))  
	SET @StaggingTable2 = ''Stagging_'' + @TableName2 + ''_Part-''  + CAST (@PartitionNumber AS nvarchar(4))
	    + ''-'' + CAST (@StartYear AS nvarchar (4)) + ''-'' +@tens +  CAST (@StartMonth AS nvarchar (2))  
	IF (@Verbose = 1)
		Select getdate() clock, @StartYear RemoveStartYear, @StartMonth RemoveStartMonth, 
			@StaggingTable1 Stagging1, @StaggingTable2 Stagging2,
			@Counter LoopCnt, @StopValue StopValue
	-- Has it been swapped out yet?
	SET @TableHasIndexRemoved1 = 0
	SELECT @TableHasIndexRemoved1  = [IndexRemoved]
	FROM [dbo].[TablePartitionProcesseds]
	WHERE [SwapTableName] = @StaggingTable1
		AND [PartitionBeginYear] = @StartYear
		AND [PartitionBeginMonth] = @StartMonth 
	SET @TableHasIndexRemoved2 = 0
	SELECT @TableHasIndexRemoved2  = [IndexRemoved]
	FROM [dbo].[TablePartitionProcesseds]
	WHERE [SwapTableName] = @StaggingTable2
	AND [PartitionBeginYear] = @StartYear
	AND [PartitionBeginMonth] = @StartMonth 
	SELECT 
		@FileGroupName1 = fg.name,
		--@LowerBoundary1   = CAST (prv_left.value AS varchar(50)),
		--@UpperBoundary1 = CAST (prv_right.value  AS varchar(50)), 
		@dataSpaceId1 = ds.data_space_id 
	FROM sys.partitions                  AS p
	JOIN sys.indexes                     AS i
		ON i.object_id = p.object_id
		AND i.index_id = p.index_id
	JOIN sys.data_spaces                 AS ds
		ON ds.data_space_id = i.data_space_id
	JOIN sys.partition_schemes           AS ps
		ON ps.data_space_id = ds.data_space_id
	JOIN sys.destination_data_spaces     AS dds2
		ON dds2.partition_scheme_id = ps.data_space_id 
		AND dds2.destination_id = p.partition_number
	JOIN sys.filegroups                  AS fg
		ON fg.data_space_id = dds2.data_space_id
	LEFT JOIN sys.partition_range_values AS prv_left
		ON ps.function_id = prv_left.function_id
		AND prv_left.boundary_id = p.partition_number - 1
	LEFT JOIN sys.partition_range_values AS prv_right
		ON ps.function_id = prv_right.function_id
		AND prv_right.boundary_id = p.partition_number
	JOIN sys.database_files AS dbf
		ON dbf.data_space_id = fg.data_space_id 
	Where OBJECT_NAME(p.object_id) = @TableName1 
		AND i.name = @FirstIndexNameController 
		AND p.partition_number = @PartitionNumber
	SELECT 
		@FileGroupName2 = fg.name,
		--@LowerBoundary2   = CAST (prv_left.value AS varchar(50)),
		--@UpperBoundary2 = CAST (prv_right.value  AS varchar(50)), 
		@dataSpaceId2 = ds.data_space_id 
	FROM sys.partitions                  AS p
	JOIN sys.indexes                     AS i
		ON i.object_id = p.object_id
		AND i.index_id = p.index_id
	JOIN sys.data_spaces                 AS ds
		ON ds.data_space_id = i.data_space_id
	JOIN sys.partition_schemes           AS ps
		ON ps.data_space_id = ds.data_space_id
	JOIN sys.destination_data_spaces     AS dds2
		ON dds2.partition_scheme_id = ps.data_space_id 
		AND dds2.destination_id = p.partition_number
	JOIN sys.filegroups                  AS fg
		ON fg.data_space_id = dds2.data_space_id
	LEFT JOIN sys.partition_range_values AS prv_left
		ON ps.function_id = prv_left.function_id
		AND prv_left.boundary_id = p.partition_number - 1
	LEFT JOIN sys.partition_range_values AS prv_right
		ON ps.function_id = prv_right.function_id
		AND prv_right.boundary_id = p.partition_number
	JOIN sys.database_files AS dbf
		ON dbf.data_space_id = fg.data_space_id 
	Where OBJECT_NAME(p.object_id) = @TableName2 
		AND i.name = @FirstIndexNameSpeed 
		AND p.partition_number = @PartitionNumber
	
	IF (@TableHasIndexRemoved1 = 0 )
		BEGIN--Table1 Controller_event_log			
			SET @NeedToCompress = 1
			SET @NeedToShrink = 1

			IF (@Verbose = 1)
				Select ''This table needs to be processed, '',  @StaggingTable1
			-- Now to the heart of the matter
			-- Set up variables for a standard swap from systems internals
			BEGIN TRANSACTION
			-- Make a new table for the big swap, create indexes and do the swap - all or nothing
			SET ANSI_NULLS ON
			SET QUOTED_IDENTIFIER ON
			SET @SQLSTATEMENT = ''CREATE TABLE [dbo].['' + @StaggingTable1 +''](
				[SignalID] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
				[Timestamp] [datetime2](7) NOT NULL,
				[EventCode] [int] NOT NULL,
				[EventParam] [int] NOT NULL
				) ON ['' + @FileGroupName1 + '']''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT SQLStatement
			EXEC sp_executesql @SQLSTATEMENT
			Select @TableCompressionType = sp.data_compression_desc
			FROM sys.partitions SP
				INNER JOIN sys.tables ST ON
				st.object_id = sp.object_id
			where name =@TableName1
				and sp.partition_number = @PartitionNumber
				AND  sp.index_id = 1
			SET @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable1 +'']'' + '' REBUILD PARTITION = ALL
				WITH (DATA_COMPRESSION = '' + @TableCompressionType + '')''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT SQLStatement
			EXEC sp_executesql @SQLSTATEMENT
			SET @IndexName = @StaggingTable1 + ''_'' + @FirstIndexNameController
			SET @FirstIndexDeleteController = @IndexName 
			-- Make indexes to allow for the big swap
			SET @SQLSTATEMENT = ''CREATE CLUSTERED INDEX ['' + @IndexName +'']
				ON [dbo].['' + @StaggingTable1 + '']'' +
				''([Timestamp] ASC) WITH (PAD_INDEX = OFF, SORT_IN_TEMPDB = OFF,
				 DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) 
				 ON ['' + @FileGroupName1 + '']''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			SET @IndexName = @StaggingTable1 + ''_'' +  @SecondIndexNameController
			SET @SecondIndexDeleteController = @IndexName 
			SET @SQLSTATEMENT = ''CREATE NONCLUSTERED INDEX ['' + @IndexName +''] 
				ON [dbo].['' + @StaggingTable1 + '']
				([SignalID] ASC,
				[Timestamp] ASC,
				[EventCode] ASC,
				[EventParam] ASC) 
				WITH (PAD_INDEX = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, 
				ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON ['' + @FileGroupName1 +'']''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			-- Add some constraints
			-- Variables are not allowed in alter tables, 
			-- so make a varchar and then execute the statement.
			-- to add a single quote use +''''''''  Double quote escapes it, then the quote, then a quote to finish the string
			SET @CHK_Constrants = ''chk_'' + @StaggingTable1 
			set @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable1 + 
				'']  WITH CHECK ADD CONSTRAINT ['' + @CHK_Constrants + '']'' + 
				'' CHECK  ([Timestamp]>= N'''''' + CAST (@StartYear AS nvarchar (4)) + ''-'' 
				+ @tens +  CAST (@StartMonth AS nvarchar (2)) + ''-01T00:00:00''''''
				+ ''AND [Timestamp]<N''''''+ CAST (@UpperBoundaryYear AS nvarchar (4)) + ''-'' 
				+ @UpperTens +  CAST (@UpperBoundaryMonth  AS nvarchar (2))
				+ ''-01T00:00:00'''')''         
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			set @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable1 + '']'' +  
				''CHECK CONSTRAINT [chk_'' + @StaggingTable1 + '']''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			-- This is the swap.  (Duck)
			set @SQLSTATEMENT = ''ALTER TABLE [MOETestPARTITION].[dbo].['' + @TableName1 + '']
				SWITCH PARTITION '' + CAST (@PartitionNumber AS nvarchar(4)) + 
				'' TO [MOETestPARTITION].[dbo].['' + @StaggingTable1 + '']''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			COMMIT TRANSACTION
			
			SET @SQLSTATEMENT = ''INSERT INTO [MOETestPartition].[dbo].['' + @TableName1 + '']
				SELECT [SignalID]
					,[Timestamp]
					,[EventCode]
					,[EventParam]
				FROM [MOETestPartition].[dbo].['' + @StaggingTable1 +'']'' +
					'' WHERE SignalID in 
						(select SignalID from [MOETestPartition].[dbo].[DatabaseArchiveExcludedSignals])''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			-- Now to drop the indexes on table 1, Controller_Event_Log
			SET @SQLSTATEMENT = ''DROP INDEX ['' + @FirstIndexDeleteController + ''] ON [dbo].[''
				+ @StaggingTable1 +''] WITH (ONLINE=OFF)''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			SET @SQLSTATEMENT = ''DROP INDEX ['' + @SecondIndexDeleteController  + ''] ON [dbo].[''
				+ @StaggingTable1 +''] WITH (ONLINE=OFF)''
			IF (@Verbose = 1)
				Select @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			INSERT INTO [dbo].[TablePartitionProcesseds] (
				 [SwapTableName]
				,[PartitionNumber]
				,[PartitionBeginYear]
				,[PartitionBeginMonth]
				,[FileGroupName]
				,[IndexRemoved]
				,[SwappedTableRemoved]
				,[TimeIndexdropped]
				,[TimeSwappedTableDropped]	)
			VALUES (
				  @StaggingTable1
				, @PartitionNumber
				, @StartYear
				, @StartMonth
				, @FileGroupName1
				, 1
				, 0
				, getdate ()
				, getdate ())
		END -- For the first table

		-- Now for the second table was going to be in an inner loop but that will have to wait
		-- Make a OR IF statement
--		IF (@SelectedDeleteOrMove = 1)  -- ALso IF Null then this is set to 0
	--		SET @TableHasIndexRemoved2 = 1
		IF (@TableHasIndexRemoved2 = 0)
			BEGIN	-- Table 2 Speed_events
			IF (@Verbose = 1)
				Select ''Found Table, indexes have been removed '', @StaggingTable2

			SET @NeedToCompress = 1
			SET @NeedToCompress = 1

			IF (@Verbose = 1)
				Select ''This table needs to be processed, '',  @StaggingTable2

			--Now to the heart of the matter
			-- Set up variables for a standard swap from systems internals

			BEGIN TRANSACTION
			-- Make a new table for the big swap, create indexes and do the swap - all or nothing
			
			SET ANSI_NULLS ON
			SET QUOTED_IDENTIFIER ON

			SET @SQLSTATEMENT = ''CREATE TABLE [dbo].['' + @staggingTable2 +''](
				[DetectorID] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
				[MPH] [int] NOT NULL,
				[KPH] [int] NOT NULL,
				[Timestamp] [datetime2](7) NOT NULL
				) ON ['' + @FileGroupName2 + '']''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 				
			EXEC sp_executesql @SQLSTATEMENT

			Select @TableCompressionType = sp.data_compression_desc
			FROM sys.partitions SP
				INNER JOIN sys.tables ST ON
				st.object_id = sp.object_id
			where name =@TableName2
				and sp.partition_number = @PartitionNumber
				AND  sp.index_id = 1

			SET @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable2 +'']'' + '' REBUILD PARTITION = ALL
				WITH (DATA_COMPRESSION = '' + @TableCompressionType + '')''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT

			SET @IndexName = @StaggingTable2 + ''_'' +  @FirstIndexNameSpeed 
			SET @FirstIndexDeleteSpeed = @IndexName 
			
			-- Make a indexes to allow for the big swap
			SET @SQLSTATEMENT = ''CREATE CLUSTERED INDEX ['' + @IndexName +'']
				ON [dbo].['' + @StaggingTable2 + '']'' +
				''([Timestamp] ASC) WITH (PAD_INDEX = OFF, SORT_IN_TEMPDB = OFF,
				 DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) 
				ON ['' + @FileGroupName2 +'']''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			SET @IndexName = @StaggingTable2 + ''_'' +  @SecondIndexNameSpeed
			SET @SecondIndexDeleteSpeed = @IndexName
			SET @SQLSTATEMENT = ''CREATE NONCLUSTERED INDEX ['' + @IndexName +''] 
				ON [dbo].['' + @StaggingTable2 + '']
				([DetectorID] ASC,
				[Timestamp] ASC) 
				WITH (PAD_INDEX = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, 
				ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON ['' + @FileGroupName2 +'']''
			
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			SET @IndexName = @staggingTable2 + ''_'' +  @ThirdIndexNameSpeed
			SET @ThirdIndexDeleteSpeed = @IndexName
			SET @SQLSTATEMENT = ''CREATE NONCLUSTERED INDEX ['' + @IndexName +''] 
				ON [dbo].['' + @StaggingTable2 + '']
				([Timestamp] ASC,
				[DetectorID] ASC) 
				WITH (PAD_INDEX = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, 
				ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON ['' + @FileGroupName2 +'']''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			-- Add some constraints
			-- Variables are not allowed in alter tables, 
			-- so make a varchar and then execute the statement.
			-- to add a single quote use +''''''''  Double quote escapes it, then the quote, then a quote to finish the string
			set @CHK_Constrants = ''chk_'' + @StaggingTable2 
			set @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable2 + 
				'']  WITH CHECK ADD CONSTRAINT ['' + @CHK_Constrants + '']'' + 
				'' CHECK  ([Timestamp]>= N'''''' + CAST (@StartYear AS nvarchar (4)) + ''-'' 
				+ @tens +  CAST (@StartMonth AS nvarchar (2)) + ''-01T00:00:00''''''
				+ ''AND [Timestamp]<N''''''+ CAST (@UpperBoundaryYear AS nvarchar (4)) + ''-'' 
				+ @UpperTens +  CAST (@UpperBoundaryMonth  AS nvarchar (2))
				+ ''-01T00:00:00'''')''         
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			
			set @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable2 + '']'' +  
				''CHECK CONSTRAINT [chk_'' + @StaggingTable2 + '']''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT

			-- Here comes the swap. (Duck your head!)
			set @SQLSTATEMENT = ''ALTER TABLE [MOETestPartition].[dbo].['' + @TableName2 + ''] ''
				+ ''SWITCH PARTITION '' + CAST (@PartitionNumber AS nvarchar(4)) + 
				'' TO [MOETestPartition].[dbo].['' + @StaggingTable2 + '']''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT
			COMMIT TRANSACTION

			-- Now there are some dectors that are to be kept.  This will break the swap Partition, 
			-- but the data will be all together in the main table.
			-- One of the two tables must have zero rows to swap a partition.
			-- The table dectors has a subset of the SignalsID.  Use this to only keep s subset of the signaqls.
			
			SET @SQLSTATEMENT = ''INSERT INTO [MOETestPartition].[dbo].['' + @TableName2 + '']
				SELECT [DetectorID]
					,[MPH]
					,[KPH]
					,[Timestamp]
				FROM [MOETestPartition].[dbo].['' + @StaggingTable2 +'']'' +
				''WHERE  DetectorID in 
					(SELECT [DetectorID]
					FROM [MOETestPartition].[dbo].[Detectors]
					WHERE [ApproachID] in 
						(SELECT [ApproachID]
						FROM [MOETestPartition].[dbo].[Approaches]
						WHERE SignalID in 
							(Select SignalId from [dbo].[DatabaseArchiveExcludedSignals])))''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT

			-- Now to drop the indexes
			SET @SQLSTATEMENT = ''DROP INDEX ['' + @FirstIndexDeleteSpeed + ''] ON [dbo].[''
				+ @StaggingTable2 +''] WITH (ONLINE=OFF)''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT

			SET @SQLSTATEMENT = ''DROP INDEX ['' + @SecondIndexDeleteSpeed + ''] ON [dbo].[''
				+ @StaggingTable2 +''] WITH (ONLINE=OFF)''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT

			SET @SQLSTATEMENT = ''DROP INDEX ['' + @ThirdIndexDeleteSpeed + ''] ON [dbo].[''
				+ @StaggingTable2 +''] WITH (ONLINE=OFF)''
			IF (@Verbose = 1)
				SELECT @SQLSTATEMENT 
			EXEC sp_executesql @SQLSTATEMENT

			INSERT INTO [dbo].[TablePartitionProcesseds] (
				 [SwapTableName]
				,[PartitionNumber]
				,[PartitionBeginYear]
				,[PartitionBeginMonth]
				,[FileGroupName]
				,[IndexRemoved]
				,[SwappedTableRemoved]
				,[TimeIndexdropped]
				,[TimeSwappedTableDropped])
			VALUES (
				  @StaggingTable2
				, @PartitionNumber
				, @StartYear
				, @StartMonth
				, @FileGroupName2
				, 1
				, 0
				, getdate ()
				, getdate ())


			END -- Second Table


			IF (@Counter > @StopDropingTable )
				BEGIN
				IF (@NeedToCompress = 1)
					BEGIN
					Select @TableCompression = sp.data_compression
					FROM sys.partitions SP
						INNER JOIN sys.tables ST ON
							st.object_id = sp.object_id
					where name =@StaggingTable1
						and sp.partition_number = @PartitionNumber
						AND  sp.index_id = 1	
					IF (@TableCompression <> 2)  -- 0 is NONE, 1 is ROW, 2 is PAGE
					BEGIN
						SET @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable1 +'']'' + '' REBUILD PARTITION = ALL
							WITH (DATA_COMPRESSION = PAGE)''
						IF (@Verbose = 1)
							Select @SQLSTATEMENT SQLStatement
						EXEC sp_executesql @SQLSTATEMENT
					END
				
					Select @TableCompression = sp.data_compression
					FROM sys.partitions SP
						INNER JOIN sys.tables ST ON
							st.object_id = sp.object_id
					where name =@StaggingTable2
						and sp.partition_number = @PartitionNumber
						AND  sp.index_id = 1	
					IF (@TableCompression <> 2)  -- 0 is NONE, 1 is ROW, 2 is PAGE
					BEGIN
						SET @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable2 +'']'' + '' REBUILD PARTITION = ALL
							WITH (DATA_COMPRESSION = PAGE)''
						IF (@Verbose = 1)
							Select @SQLSTATEMENT SQLStatement
						EXEC sp_executesql @SQLSTATEMENT
					END

					Select @TableCompression = sp.data_compression
					FROM sys.partitions SP
						INNER JOIN sys.tables ST ON
							st.object_id = sp.object_id
					where name =@TableName2
						and sp.partition_number = @PartitionNumber
						AND  sp.index_id = 1	
					IF (@TableCompression <> 2)  -- 0 is NONE, 1 is ROW, 2 is PAGE
					BEGIN
						SET @SQLSTATEMENT = ''ALTER TABLE [dbo].['' + @StaggingTable2 +'']'' + '' REBUILD PARTITION = ALL
							WITH (DATA_COMPRESSION = PAGE)''
						IF (@Verbose = 1)
							Select @SQLSTATEMENT SQLStatement
						EXEC sp_executesql @SQLSTATEMENT
					
					END

				END
			END

			-- Should the tables be droped?
			IF (@Counter <= @StopDropingTable)
			BEGIN
				-- Table 1
				SET @TableHasSwappedTableRemoved = 0
				SELECT @TableHasSwappedTableRemoved  = [SwappedTableRemoved]
				FROM [dbo].[TablePartitionProcesseds]
				WHERE [SwapTableName] = @StaggingTable1
					AND [PartitionBeginYear] = @StartYear
					AND [PartitionBeginMonth] = @StartMonth 
			
				IF (@TableHasSwappedTableRemoved = 0)
					BEGIN
						IF OBJECT_ID(@StaggingTable1, N''U'') IS NOT NULL
							BEGIN
								SET @NeedToShrink = 1
	 							SET @SQLSTATEMENT = ''DROP TABLE [dbo].['' 
									+ @StaggingTable1 + '']''
								IF (@Verbose = 1)
									SELECT @SQLSTATEMENT 
								EXEC sp_executesql @SQLSTATEMENT 

								UPDATE [dbo].[TablePartitionProcesseds] 
								SET [SwappedTableRemoved] = 1
									,[TimeSwappedTableDropped] = getdate()
								WHERE SwapTableName = @StaggingTable1
									AND PartitionNumber = @PartitionNumber
									AND PartitionBeginYear = @StartYear
									AND PartitionBeginMonth = @StartMonth 
							END
						END

				-- Table 2
				SET @TableHasSwappedTableRemoved = 0
				SELECT @TableHasSwappedTableRemoved  = [SwappedTableRemoved]
				FROM [dbo].[TablePartitionProcesseds]
				WHERE [SwapTableName] = @StaggingTable2
					AND [PartitionBeginYear] = @StartYear
					AND [PartitionBeginMonth] = @StartMonth 
		
				IF (@TableHasSwappedTableRemoved = 0)
					 BEGIN
						IF OBJECT_ID(@StaggingTable2, N''U'') IS NOT NULL
							BEGIN
								SET @NeedToShrink = 1
								SET @SQLSTATEMENT = ''DROP TABLE [dbo].['' 
									+ @StaggingTable2 + '']''
								IF (@Verbose = 1)
									SELECT @SQLSTATEMENT 
								EXEC sp_executesql @SQLSTATEMENT 

								UPDATE [dbo].[TablePartitionProcesseds] 
									SET [SwappedTableRemoved] = 1
										,[TimeSwappedTableDropped] = getdate()
									WHERE SwapTableName = @StaggingTable2
										AND PartitionNumber = @PartitionNumber
										AND PartitionBeginYear = @StartYear
										AND PartitionBeginMonth = @StartMonth 
							END
						END
					END


			IF (@NeedToShrink  = 1)
				BEGIN
					SET @SQLSTATEMENT = ''<NOT DOING> DBCC SHRINKFILE (N'''''' + @FileGroupName1 + '''''' , 1)''
					IF (@Verbose = 1)
						SELECT @SQLSTATEMENT 
					
					INSERT INTO [dbo].[TablePartitionProcesseds] (
						 [SwapTableName]
						,[PartitionNumber]
						,[PartitionBeginYear]
						,[PartitionBeginMonth]
						,[FileGroupName]
						,[IndexRemoved]
						,[SwappedTableRemoved]
						,[TimeIndexdropped]
						,[TimeSwappedTableDropped])
					VALUES (
						  @SQLSTATEMENT 
						, @PartitionNumber
						, @StartYear
						, @StartMonth
						, @FileGroupName1
						, 1
						, 0
						, getdate ()
						, getdate ())

						--IF (@SelectedDeleteOrMove <> 0)
						--EXEC sp_executesql @SQLSTATEMENT 

						UPDATE [dbo].[TablePartitionProcesseds] 
							SET [IndexRemoved]  = @SelectedDeleteOrMove 
								,[SwappedTableRemoved] = 1
								,[TimeSwappedTableDropped] = getdate()
							WHERE SwapTableName = @SQLSTATEMENT 
								AND PartitionNumber = @PartitionNumber
								AND PartitionBeginYear = @StartYear
								AND PartitionBeginMonth = @StartMonth 
								AND FileGroupName = @FileGroupName1

					IF (@FileGroupName1 <> @FileGroupName2)
						Begin

							SET @SQLSTATEMENT = ''<NOT DOING> DBCC SHRINKFILE (N'''''' + @FileGroupName2 + '''''' , 1)''
							IF (@Verbose = 1)
								SELECT @SQLSTATEMENT 
							INSERT INTO [dbo].[TablePartitionProcesseds] (
								 [SwapTableName]
								,[PartitionNumber]
								,[PartitionBeginYear]
								,[PartitionBeginMonth]
								,[FileGroupName]
								,[IndexRemoved]
								,[SwappedTableRemoved]
								,[TimeIndexdropped]
								,[TimeSwappedTableDropped])
							VALUES (
								@SQLSTATEMENT 
								, @PartitionNumber
								, @StartYear
								, @StartMonth
								, @FileGroupName2 
								, 1
								, 0
								, getdate ()
								, getdate ())

							--IF (@SelectedDeleteOrMove <> 0)
							--EXEC sp_executesql @SQLSTATEMENT 

							UPDATE [dbo].[TablePartitionProcesseds] 
								SET [IndexRemoved]  = @SelectedDeleteOrMove
									,[SwappedTableRemoved] = 1
									,[TimeSwappedTableDropped] = getdate()
								WHERE SwapTableName = @SQLSTATEMENT 
									AND PartitionNumber = @PartitionNumber
									AND PartitionBeginYear = @StartYear
									AND PartitionBeginMonth = @StartMonth 
									AND FileGroupName = @FileGroupName2

						END 
			END

-- Lets go again, another month
		SET @Counter = @Counter + 1

		SET @StartMonth = @StartMonth + 1
		if (@StartMonth > 12 )
		Begin
			-- Another year?
			SET @StartMonth = 1
			SET @Startyear = @StartYear + 1
		END -- end of changing months and another year

		IF (@Verbose = 1)
			SELECT ''Bottom of Main Loop '' Info, @Counter LoopCounter, @StartMonth StartMonth, @StartYear StartYear
END

INSERT INTO [dbo].[TablePartitionProcesseds] (
	 [SwapTableName]
	,[PartitionNumber]
	,[PartitionBeginYear]
	,[PartitionBeginMonth]
	,[FileGroupName]
	,[IndexRemoved]
	,[SwappedTableRemoved]
	,[TimeIndexdropped]
	,[TimeSwappedTableDropped])
VALUES (
	''END of Move, Delete, and Shrink''
	, @MonthsToKeepIndex
	, @MonthsToKeepData
	, @SelectedDeleteOrMove
	, ''We are done for now!''
	, 0
	, 0
	, @CurrentTime
	, getdate ())
', 
		@database_name=N'MOETestPartition', 
		@flags=0
--GO
--USE [msdb]
--GO
EXEC msdb.dbo.sp_update_job @job_name=N'Reclaim File Space', 
		@enabled=1, 
		@start_step_id=1, 
		@notify_level_eventlog=2, 
		@notify_level_email=2, 
		@notify_level_page=2, 
		@delete_level=0, 
		@description=N'This job reclaims file space by swapping out a partitioned table, keeping the signal information for the signals in the main table as listed in the table, [DatabaseArchiveExcludedSignals].  It gets additional information from the table, [ApplicationSettings].', 
		@category_name=N'Database Maintenance', 
		@owner_login_name=N'UTAH\asanchez', 
		@notify_email_operator_name=N'', 
		@notify_page_operator_name=N''
--GO
--USE [msdb]
--GO
DECLARE @schedule_id int
EXEC msdb.dbo.sp_add_jobschedule @job_name=N'Reclaim File Space', @name=N'Monthly-First-Friday Reclaim filespace', 
		@enabled=1, 
		@freq_type=32, 
		@freq_interval=6, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=1, 
		@freq_recurrence_factor=1, 
		@active_start_date=20180411, 
		@active_end_date=99991231, 
		@active_start_time=200000, 
		@active_end_time=235959, @schedule_id = @schedule_id OUTPUT
select @schedule_id
--GO
