# FluidVoice Local API Documentation

The FluidVoice Local API allows you to submit audio files for transcription, check their status, and retrieve results programmatically. The API runs locally on port `7086` by default.

## Base URL
`http://localhost:7086`

## Endpoints

### 1. List Available Models
Retrieves a list of available transcription models.

- **Endpoint**: `GET /models`
- **Response**: JSON object containing a list of model IDs.

```json
{
  "models": ["whisper-base", "whisper-medium", "whisper-large-v3", ...]
}
```

---

### 2. Submit Transcription Job
Queues an audio file for transcription.

- **Endpoint**: `POST /transcribe`
- **Content-Type**: `application/json`
- **Body Parameters**:
    - `url` (string, required): The absolute URL of the local file to transcribe (e.g., `file:///Users/me/audio.wav`).
    - `model` (string, optional): The ID of the model to use. If omitted, uses the application default.

- **Response**:
    - `200 OK`: Job accepted.
    - `400 Bad Request`: Invalid JSON or missing URL.

```json
{
  "id": "file:///Users/me/audio.wav",
  "status": "pending"
}
```

---

### 3. Check Job Status
Checks the status of a transcription job.

- **Endpoint**: `GET /status`
- **Query Parameters**:
    - `url` (string, required): The URL of the file.
    - `model` (string, optional): The model ID used. Required only if multiple jobs exist for the same file.

- **Response**:
    - `200 OK`: Returns job details.
    - `404 Not Found`: Job not found.
    - `409 Conflict`: Multiple jobs found for this URL. Returns a list of choices to help you refine the request.

**Success Response (200):**
```json
{
  "id": "UUID-STRING",
  "status": "completed", // pending, processing, completed, failed
  "created_at": 1700000000,
  "model": "whisper-medium",
  "processing_duration": 12.5,
  "error": null
}
```

**Ambiguity Response (409):**
```json
{
  "error": "Ambiguous request...",
  "choices": [
    {"id": "uuid-1", "model": "base", "status": "completed"},
    {"id": "uuid-2", "model": "medium", "status": "pending"}
  ]
}
```

---

### 4. Get Transcription Result
Retrieves the transcribed text.

- **Endpoint**: `GET /result`
- **Query Parameters**:
    - `url` (string, required): The URL of the file.
    - `model` (string, optional): The model ID used. Required if ambiguous.
    - `format` (string, optional): Output format. `text` (default) or `vtt`.

- **Response**:
    - `200 OK`: Returns the transcription text (plain text or VTT).
    - `400 Bad Request`: Job not completed or missing parameters.
    - `404 Not Found`: Job not found.
    - `409 Conflict`: Ambiguous request (see `/status`).

---

### 5. List All Jobs
Returns a list of all current jobs in the backlog.

- **Endpoint**: `GET /list`
- **Response**: JSON array of job summaries.

```json
[
  {
    "id": "uuid-1",
    "url": "file:///path/to/a.wav",
    "status": "completed",
    "model": "base",
    "processing_duration": 5.2
  },
  ...
]
```

---

### 6. Delete Job
Removes a job from the backlog.

- **Endpoint**: `DELETE /backlog`
- **Query Parameters**:
    - `url` (string, required): The URL of the file.
    - `model` (string, optional): The model ID to delete. Required if ambiguous.

- **Response**:
    - `200 OK`: Deleted.
    - `404 Not Found`: Job not found.
    - `409 Conflict`: Ambiguous request.

## Error Handling

- **400 Bad Request**: Missing parameters or invalid request format.
- **404 Not Found**: The specified job does not exist.
- **409 Conflict**: The request matched multiple jobs (same file, different models). precise the `model` parameter.
- **500 Internal Server Error**: Unexpected server error.
