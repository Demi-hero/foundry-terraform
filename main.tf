provider "google" {
  region = "europe-west2"
}

# --- 1. DATA & IAM PERMISSIONS ---
data "google_project" "project" {}

# FIX: Grant Secret Accessor to the VM's service account
resource "google_project_iam_member" "secret_accessor" {
  project = data.google_project.project.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# FIX: Grant permission for the Instance Schedule to run
resource "google_project_iam_member" "instance_schedule_admin" {
  project = data.google_project.project.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:service-${data.google_project.project.number}@compute-system.iam.gserviceaccount.com"
}

# --- 2. THE SCHEDULES ---
resource "google_compute_resource_policy" "session_schedule" {
  name   = "foundry-tuesday-schedule"
  region = "europe-west2"
  instance_schedule_policy {
    vm_start_schedule { schedule = "0 19 * * 2" }   # 7:00 PM Tuesday
    vm_stop_schedule  { schedule = "30 23 * * 2" }  # 11:30 PM Tuesday
    time_zone = "Europe/London"
  }
}

resource "google_compute_resource_policy" "weekly_backup" {
  name   = "foundry-weekly-snapshot"
  region = "europe-west2"
  snapshot_schedule_policy {
    schedule {
      weekly_schedule {
        day_of_weeks { 
          day = "WEDNESDAY"
          start_time = "01:00"
          }
      }
    }
    retention_policy { 
      max_retention_days = 30 
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
}

# --- 3. STORAGE & NETWORKING ---
resource "google_compute_firewall" "foundry_firewall" {
  name    = "allow-foundry"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["30000"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["foundry-server"]
}

resource "google_compute_disk" "foundry_data" {
  name = "foundry-data-disk"
  type = "pd-ssd"
  zone = "europe-west2-a"
  size = 20
}

# FIX: Correct way to attach the backup policy
resource "google_compute_disk_resource_policy_attachment" "backup_attachment" {
  name = google_compute_resource_policy.weekly_backup.name
  disk = google_compute_disk.foundry_data.name
  zone = "europe-west2-a"
}

# --- 4. THE VM ---
resource "google_compute_instance" "foundry_vm" {
  name         = "foundry-vtt"
  machine_type = "e2-small"
  zone         = "europe-west2-a"
  tags         = ["foundry-server"]

  resource_policies = [google_compute_resource_policy.session_schedule.id]

  boot_disk {
    initialize_params { image = "ubuntu-os-cloud/ubuntu-2204-lts" }
  }

  network_interface {
    network = "default"
    access_config { } # Provides ephemeral IP
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    # 1. Install Docker
    apt-get update && apt-get install -y docker.io

    # 2. Mount and Fix Permissions (Correct Order)
    mkdir -p /mnt/foundry-data
    DISK_ID="/dev/disk/by-id/google-foundry-data-disk"
    sudo blkid $DISK_ID || sudo mkfs.ext4 -m 0 $DISK_ID
    sudo mount -o discard,defaults $DISK_ID /mnt/foundry-data
    
    # FIX: Ownership must be set AFTER mount
    sudo chown -R 1000:1000 /mnt/foundry-data

    # 3. Fetch Dynamic Info
    F_USER=$(gcloud secrets versions access latest --secret="john_foundry_username")
    F_PASS=$(gcloud secrets versions access latest --secret="john_foundry_password")
    PUBLIC_IP=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

    # 4. Run Foundry & Wait for Health
    docker rm -f foundry || true
    docker run -d --name foundry --restart always \
      -v /mnt/foundry-data:/data \
      -e FOUNDRY_USERNAME="$F_USER" \
      -e FOUNDRY_PASSWORD="$F_PASS" \
      -p 30000:30000/tcp felddy/foundryvtt:13

    while ! nc -z localhost 30000; do sleep 30; done

    # 5. Notify Discord
    curl -H "Content-Type: application/json" -X POST -d "{\"content\": \" **Foundry VTT Online!** \n http://$${PUBLIC_IP}:30000\"}" https://discord.com/api/webhooks/Discord_webhook_here
  EOT

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

resource "google_compute_attached_disk" "default" {
  disk        = google_compute_disk.foundry_data.id
  instance    = google_compute_instance.foundry_vm.id
  device_name = "foundry-data-disk"
}
