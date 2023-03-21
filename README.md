# AzLogDcrIngestPSLogHub
 Solution that acts as an intermediate hub for "no internet connected" endpoints or incompliant endpoints, where you will be sending data using Azure Pipeline/Log Ingestion API

## Flow highlevel
![Architecture](img/Architecture.png.png)



## Detailed flow

### Data collection
Instead of sending to DCE/Azure Pipeline, server sends JSON-file to specific UNC-path (LogHubPath).
![Collection from REST endpoint - ServerInspector](img/LogHub-collection.png)

### Upload format
Data-format contains the following fields
![Format of JSON data-file coming from REST endpoint](img/LogHub-upload-format.png)


### Temporary inbound location (max 10 sec)
Files are sent to teporary loghub path and kept there for max 10 sec.
![Inbound folder from endpoints](img/LogHub-inbound.png)

### Upload to Azure
On the Log-hub server, there is a job, which is scanning the LogHubPath for new files (every 10 sec)
It will process the files and send it to the correct DCE – with DCR information – and if succesfully, delete the file.

![Data being uploaded by log-hub (AzLogDcrIngestPSLogHub script)](img/LogHub-upload.png)
