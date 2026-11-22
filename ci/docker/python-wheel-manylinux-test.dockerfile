# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

ARG arch
ARG python

# minio server + mc client at the releases ci/scripts/install_minio.sh pins:
# dl.min.io no longer serves community MinIO binaries (HTTP 410), so build
# those exact releases from source
FROM golang:1.22-bookworm AS minio-build
RUN go install -ldflags="-X github.com/minio/minio/cmd.ReleaseTag=RELEASE.2022-05-26T05-48-41Z -X github.com/minio/minio/cmd.Version=2022-05-26T05:48:41Z" \
      github.com/minio/minio@RELEASE.2022-05-26T05-48-41Z && \
    go install -ldflags="-X github.com/minio/mc/cmd.ReleaseTag=RELEASE.2022-05-09T04-08-26Z -X github.com/minio/mc/cmd.Version=2022-05-09T04:08:26Z" \
      github.com/minio/mc@RELEASE.2022-05-09T04-08-26Z

# bookworm: the base the floating tag pointed at when 14.0.2 was released
# (newer bases ship no time zone database, which the ORC reader aborts on)
FROM ${arch}/python:${python}-bookworm

# RUN pip install --upgrade pip

# pandas doesn't provide wheel for aarch64 yet, so cache the compiled
# test dependencies in a docker image
ARG pip_index_url=https://pypi.org/simple
COPY python/requirements-wheel-test.txt /arrow/python/
RUN PIP_INDEX_URL=${pip_index_url} pip install -r /arrow/python/requirements-wheel-test.txt

COPY ci/scripts/install_gcs_testbench.sh /arrow/ci/scripts/
RUN PYTHON=python /arrow/ci/scripts/install_gcs_testbench.sh default

# Optional test dependencies, so the suite exercises them instead of
# skipping: gdb (test_gdb), the minio server + mc client built above (S3
# filesystem tests), and the Python packages the tests importorskip. numpy
# stays at the version requirements-wheel-test.txt pinned.
RUN apt-get update -y -q && \
    apt-get install -y -q --no-install-recommends gdb && \
    rm -rf /var/lib/apt/lists/*
COPY --from=minio-build /go/bin/minio /go/bin/mc /usr/local/bin/
RUN minio --version && mc --version && gdb --version | head -1
# scipy/sparse: numba must support the numpy pinned by
# requirements-wheel-test.txt, so pick the numba release per numpy (numba
# 0.59, the first with Python 3.12 / numpy 1.26 support, postdates the
# release and comes from pypi.org); the last line fails the build if any of
# them still cannot be imported.
RUN pip freeze | grep -i '^numpy==' > /tmp/test-constraints.txt && \
    PIP_INDEX_URL=${pip_index_url} pip install --prefer-binary -c /tmp/test-constraints.txt \
      cloudpickle fsspec "s3fs[boto3]" minio && \
    PIP_INDEX_URL=${pip_index_url} pip install --only-binary :all: -c /tmp/test-constraints.txt scipy && \
    NUMBA=$(python -c "import numpy; print({'1.19': '0.53.1', '1.21': '0.56.4', '1.23': '0.57.1'}.get('.'.join(numpy.__version__.split('.')[:2]), ''))") && \
    if [ -n "$NUMBA" ]; then \
      PIP_INDEX_URL=${pip_index_url} pip install --only-binary :all: -c /tmp/test-constraints.txt "numba==$NUMBA" "sparse==0.14.0"; \
    else \
      echo "numba for numpy 1.26 / Python 3.12 (0.59) postdates the release; installing it from pypi.org" && \
      PIP_INDEX_URL=https://pypi.org/simple pip install --only-binary :all: -c /tmp/test-constraints.txt "numba==0.59.1" "sparse==0.14.0"; \
    fi && \
    python -c "import cloudpickle, fsspec, s3fs, minio, scipy.sparse, sparse, numba, scipy; print('optional test deps OK: scipy', scipy.__version__, 'sparse', sparse.__version__, 'numba', numba.__version__)" && \
    pip list
