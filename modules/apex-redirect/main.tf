# A 301 from the bare apex to the website, on http and https. The proxies serve
# only <slug>.<apex> and refuse the apex's SNI, so CloudFront answers it; its
# certificates must live in us-east-1, so the default provider has to be there.

module "cert" {
  source = "../acm-cert"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  domain_name   = var.apex
  dns_zone_name = var.apex

  tags = var.tags
}

resource "aws_cloudfront_function" "redirect" {
  name    = "${var.name}-apex-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "Redirects ${var.apex} to ${var.target}"
  publish = true

  # Cached for a day, not forever, so the target can still change.
  code = <<-EOT
    function handler(event) {
      return {
        statusCode: 301,
        statusDescription: "Moved Permanently",
        headers: {
          location: { value: ${jsonencode(var.target)} },
          "cache-control": { value: "max-age=86400" },
        },
      };
    }
  EOT
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_distribution" "redirect" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "Redirects ${var.apex} to ${var.target}"
  aliases         = [var.apex]

  # Never reached: the viewer-request function answers every request.
  origin {
    origin_id   = "target"
    domain_name = regex("^https?://([^/:]+)", var.target)[0]

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "target"
    viewer_protocol_policy = "allow-all"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.redirect.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = module.cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = var.tags
}

data "aws_route53_zone" "apex" {
  provider     = aws.dns
  name         = var.apex
  private_zone = false
}

resource "aws_route53_record" "apex" {
  provider = aws.dns
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.apex.zone_id
  name    = var.apex
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.redirect.domain_name
    zone_id                = aws_cloudfront_distribution.redirect.hosted_zone_id
    evaluate_target_health = false
  }
}
