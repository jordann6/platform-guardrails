# Compliant GCP fixture. The policy suite must report zero failures against this.
# Kept separate from examples/pass because the GCP label rules only engage on a
# repo whose providers are all google, and --combine sees one repo per run.

provider "google" {
  region = "us-central1"

  default_labels = {
    project     = "guardrails-fixture"
    owner       = "jordan"
    managed-by  = "terraform"
    cost_center = "cc-0001"
  }
}

module "project" {
  source = "./modules/project"
}

resource "google_storage_bucket" "artifacts" {
  name                        = "guardrails-fixture-artifacts"
  location                    = "US"
  uniform_bucket_level_access = true

  labels = {
    environment = "dev"
  }
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "allow-iap-ssh"
  network       = "shared-vpc"
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "https" {
  name          = "allow-https"
  network       = "shared-vpc"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_instance" "private" {
  name         = "private"
  machine_type = "e2-micro"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = "workload"
  }
}

resource "google_sql_database_instance" "db" {
  name             = "db"
  database_version = "POSTGRES_16"

  settings {
    tier = "db-custom-1-3840"

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/p/global/networks/restricted"
    }
  }
}
