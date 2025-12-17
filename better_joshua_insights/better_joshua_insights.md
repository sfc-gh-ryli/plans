The goal is to ingest all Joshua data into Snowhouse (passed tests as well as failures). Today, we only ingest failures/summaries. Snowhouse is the Snowflake internal database for miscellaneous developer data needs. You should be able to identify where this occurs today. Joshua logic mostly lives in fdb_snowflake/joshua; specific uses for Joshua (such as bindingtester and testharness) will live in frostdb. Likely this data ingestion is handled in fdb_snowflake. The main question to answer with the implementation of this is how to ingest this data efficiently, since this introduces much more data to ingest than before.

Step 2 is to provide insights into Joshua ensemble runs based on all of this data, including:
1. Test Distribution 
2. Stats like test duration, memory and cpu 
3. Test Failure details
4. Make data available of past runs for analysis/aggregation

The Joshua data should include the needed data for these.

To perform this task, you should be able to identify where the logic currently lives, how Joshua is ran and how the data is ingested/where it is found in Snowhouse, and how we can ingest data for everything. If you can also understand how the development cycle should look, e.g. how we can test this and look into the data in Snowhouse and iterate on it, please include that.
