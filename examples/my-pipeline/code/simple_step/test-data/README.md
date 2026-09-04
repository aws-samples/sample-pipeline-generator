# Test Data

Dummy data for integration testing the Step Function pipeline.

## Structure

```
input/simulation-data/
├── session-001/
│   └── data.jsonl      # 3 JSONL records (sensor bla-01)
└── session-002/
    └── data.jsonl      # 2 JSONL records (camera sensor)
```

## Usage

Upload to the source S3 bucket:

```bash
aws s3 sync ./test-data/ s3://<source-bucket>/
```

Then trigger the Step Function with:

```json
{
  "inputs": {
    "root_prefix": "input/simulation-data"
  }
}
```

The `simple_step` batch job reads every object under the prefix and writes result summaries to the intermediate bucket. The `fan_out` Map step then discovers those result prefixes and runs `process_item` on each in parallel.
