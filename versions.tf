terraform {
  required_version = ">= 1.5.7, < 2.0.0"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    volcenginecc = {
      source  = "volcengine/volcenginecc"
      version = "~> 0.0.74"
    }
  }
}
