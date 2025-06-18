#!/bin/sh
set -x

# static string from root
curl -X GET http://localhost:8080/

# with URL parameter
curl -X GET http://localhost:8080/params/42

# with query parameter
curl -X GET http://localhost:8080/query?name=me

# with Body
curl -X GET http://localhost:8080/echo -d '{"id": 41, "name": "its me"}'

