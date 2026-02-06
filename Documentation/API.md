# FluidVoice Local API Documentation

The FluidVoice Local API allows you to submit audio files for transcription, check their status, and retrieve results programmatically. The API runs locally on port `7086` by default.

## Base URL
`http://127.0.0.1:7086`

> **Note**: The API binds strictly to **IPv4 loopback** (`127.0.0.1`). It is **not** accessible via `::1` (IPv6) or other network interfaces. For best compatibility, use `127.0.0.1` instead of `localhost`.

> **Port**: The default port is `7086`, but this can be changed in the app settings (File Transcription API > Port).

## Endpoints

### 1. List Available Models
Retrieves a list of available transcription models that are **downloaded and ready to use**.

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
    - `id` (string, optional): The UUID of the job (RECOMMENDED). Takes precedence over `url`.
    - `url` (string, optional): The URL of the file. Legacy/fallback if `id` is not provided.
    - `model` (string, optional): The model ID used. Required only if using `url` and multiple jobs exist for the same file.

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
    - `id` (string, optional): The UUID of the job (RECOMMENDED).
    - `url` (string, optional): The URL of the file.
    - `model` (string, optional): The model ID used. Required if using `url` and ambiguous.
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
    - `id` (string, optional): The UUID of the job to delete (RECOMMENDED).
    - `url` (string, optional): The URL of the file.
    - `model` (string, optional): The model ID to delete. Required if using `url` and ambiguous.

- **Response**:
    - `200 OK`: Deleted.
    - `404 Not Found`: Job not found.
    - `409 Conflict`: Ambiguous request.

## Error Handling

- **400 Bad Request**: Missing parameters or invalid request format.
- **404 Not Found**: The specified job does not exist.
- **409 Conflict**: The request matched multiple jobs (same file, different models). precise the `model` parameter.
- **500 Internal Server Error**: Unexpected server error.
