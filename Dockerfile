FROM fishtownanalytics/dbt:1.0.0

RUN apt-get update \
  && apt-get dist-upgrade -y \
  && apt-get install -y --no-install-recommends \
  git \
  ssh-client \
  software-properties-common \
  make \
  build-essential \
  ca-certificates \
  libpq-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN pip install --upgrade pip
RUN pip --no-cache-dir install --upgrade awscli
RUN pip install dbt-snowflake
RUN pip install moto[all]
RUN pip install pytest

COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt
RUN rm requirements.txt

COPY src /src
COPY tests /tests
COPY dbt_download /dbt_download
COPY Makefile /Makefile
COPY profiles/profiles.yml ~/.dbt/profiles.yml

WORKDIR /
ENTRYPOINT ["python3", "-m", "src.runner"]
