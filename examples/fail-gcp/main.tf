# Non-compliant GCP fixture. Every block here must trip at least one rule.

provider "google" {
  region = "us-central1"

  default_labels = {
    project     = "guardrails-fixture"
    cost_center = "todo"
  }
}

module "project" {
  source = "./modules/project"
}

resource "google_storage_bucket" "unlabelled" {
  name     = "guardrails-fixture-unlabelled"
  location = "US"

  labels = {
    environment = "dev"
  }
}

resource "google_storage_bucket_iam_member" "public" {
  bucket = "guardrails-fixture-unlabelled"
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_compute_firewall" "ssh_world" {
  name          = "allow-ssh-world"
  network       = "shared-vpc"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall_policy_rule" "org_allow_world" {
  firewall_policy = "123"
  priority        = 1000
  action          = "allow"
  direction       = "INGRESS"

  match {
    src_ip_ranges = ["0.0.0.0/0"]

    layer4_configs {
      ip_protocol = "tcp"
    }
  }
}

resource "google_service_account_key" "static" {
  service_account_id = "sa-ci"
}

resource "google_compute_instance" "public" {
  name         = "public"
  machine_type = "n2-standard-32"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = "workload"
    access_config {}
  }
}

resource "google_sql_database_instance" "public" {
  name             = "public-db"
  database_version = "POSTGRES_16"

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "REGIONAL"

    ip_configuration {
      ipv4_enabled = true
    }
  }
}

resource "google_project_iam_member" "editor" {
  project = "p"
  role    = "roles/editor"
  member  = "user:someone@example.com"
}
