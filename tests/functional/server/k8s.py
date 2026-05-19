# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)

from typing import Annotated

from fastapi import Header, HTTPException

from .app import app


TOKEN = "test-k8s-token"
NAMESPACE = "default"
POD_NAME = "test-pod"

# Pod manifest as returned by the chalk operator's /v1/podinfo endpoint.
# Note: the operator intentionally strips all container env vars before
# returning the manifest so that sensitive values are never reported.
# Cluster info is not included here - it is injected by the chalk operator
# as the CHALK_K8S_METADATA env var.
POD_MANIFEST = {
    "metadata": {
        "name": POD_NAME,
        "namespace": NAMESPACE,
        "labels": {
            "app": "test-app",
            "version": "v1",
        },
        "annotations": {
            "deployment.kubernetes.io/revision": "1",
        },
    },
    "spec": {
        "volumes": [
            {
                "name": "app-config",
                "configMap": {
                    "name": "app-configmap",
                },
            },
            {
                "name": "app-config-key",
                "configMap": {
                    "name": "app-configmap",
                    "items": [
                        {"key": "config.yaml", "path": "config.yaml"},
                    ],
                },
            },
            {
                "name": "app-secret",
                "secret": {
                    "secretName": "app-secret",
                },
            },
            {
                # projected volumes (e.g. service account tokens) should be
                # excluded from the deployment id calculation
                "name": "kube-api-access",
                "projected": {
                    "sources": [
                        {"serviceAccountToken": {"path": "token"}},
                        {"configMap": {"name": "kube-root-ca.crt"}},
                        {
                            "downwardAPI": {
                                "items": [
                                    {
                                        "path": "namespace",
                                        "fieldRef": {"fieldPath": "metadata.namespace"},
                                    }
                                ]
                            }
                        },
                    ],
                },
            },
        ],
        "containers": [
            {
                "name": "app",
                # the chalk operator normalizes env var values before returning
                # the manifest: static values are replaced with the literal
                # string "string" so that sensitive values are never reported;
                # valueFrom references are passed through as-is
                "env": [
                    {
                        "name": "APP_ENV",
                        # normalized to "string" by the chalk operator
                        "value": "string",
                    },
                    {
                        "name": "LOG_LEVEL",
                        # normalized to "string" by the chalk operator
                        "value": "string",
                    },
                    {
                        "name": "DB_HOST",
                        "valueFrom": {
                            "configMapKeyRef": {
                                "name": "app-configmap",
                                "key": "db_host",
                            }
                        },
                    },
                    {
                        "name": "DB_PASSWORD",
                        "valueFrom": {
                            "secretKeyRef": {
                                "name": "app-secret",
                                "key": "password",
                            }
                        },
                    },
                    {
                        # downward API env vars should be excluded from the
                        # deployment id calculation
                        "name": "NODE_IP",
                        "valueFrom": {
                            "fieldRef": {
                                "fieldPath": "status.hostIP",
                            }
                        },
                    },
                ],
                "ports": [
                    {"containerPort": 8080, "protocol": "TCP"},
                    {"containerPort": 9090, "protocol": "TCP"},
                ],
                "volumeMounts": [
                    {
                        "name": "app-config",
                        "mountPath": "/etc/config",
                    },
                    {
                        "name": "app-config-key",
                        "mountPath": "/etc/config/config.yaml",
                        "subPath": "config.yaml",
                    },
                    {
                        "name": "app-secret",
                        "mountPath": "/etc/secret",
                    },
                    {
                        "name": "kube-api-access",
                        "mountPath": "/var/run/secrets/kubernetes.io/serviceaccount",
                    },
                ],
            },
        ],
    },
}


@app.get("/v1/podinfo/{namespace}/{pod_name}")
def podinfo(
    namespace: str,
    pod_name: str,
    authorization: Annotated[str, Header()],
):
    if authorization != f"Bearer {TOKEN}":
        raise HTTPException(status_code=401, detail="unauthorized")
    if namespace != NAMESPACE or pod_name != POD_NAME:
        raise HTTPException(status_code=404, detail="pod not found")
    return POD_MANIFEST
