"""ABAC Policy Decision Point (PDP) engine in Python.

This module provides an alternative PDP implementation that evaluates
access policies stored in the database. It mirrors the PL/pgSQL
evaluate_access_dynamic function but runs in the application layer.
"""

from database import query_all, query_one


def get_user(user_id):
    return query_one("SELECT * FROM users WHERE user_id = %s", (user_id,))


def get_resource(resource_id):
    return query_one("SELECT * FROM resources WHERE resource_id = %s", (resource_id,))


def get_user_attribute(user_id, attr_key):
    row = query_one(
        """SELECT attr_value FROM user_attributes
           WHERE user_id = %s AND attr_key = %s
             AND valid_from <= NOW()
             AND (valid_to IS NULL OR valid_to > NOW())
           ORDER BY valid_from DESC LIMIT 1""",
        (user_id, attr_key),
    )
    return row["attr_value"] if row else None


def get_active_policies():
    return query_all(
        """SELECT p.*, array_agg(
                jsonb_build_object(
                    'attribute_type', pc.attribute_type,
                    'attribute_key', pc.attribute_key,
                    'operator', pc.operator,
                    'compare_value', pc.compare_value,
                    'value_type', pc.value_type
                )
           ) AS conditions
           FROM policies p
           JOIN policy_conditions pc ON pc.policy_id = p.policy_id
           WHERE p.is_enabled = TRUE
           GROUP BY p.policy_id
           ORDER BY p.priority DESC"""
    )


def _resolve_value(ref, user, resource):
    """Resolve cross-references like resource.classification_level."""
    if isinstance(ref, str) and "." in ref:
        parts = ref.split(".", 1)
        if parts[0] == "resource":
            return str(resource.get(parts[1], ""))
        if parts[0] == "subject":
            return str(user.get(parts[1], ""))
    return ref


def _compare(actual, operator, expected, value_type):
    """Evaluate a single condition comparison."""
    if actual is None:
        return False
    if value_type == "int":
        try:
            a, e = int(actual), int(expected)
        except (ValueError, TypeError):
            return False
        ops = {"eq": a == e, "neq": a != e, "gt": a > e, "gte": a >= e, "lt": a < e, "lte": a <= e}
        return ops.get(operator, False)
    if value_type == "list":
        items = [x.strip() for x in expected.split(",")]
        if operator == "in":
            return actual in items
        if operator == "not_in":
            return actual not in items
        return False
    # text / boolean
    if operator == "eq":
        return str(actual) == str(expected)
    if operator == "neq":
        return str(actual) != str(expected)
    return False


def evaluate_access(user_id, resource_id, action, env):
    """Evaluate an access request and return (decision, reason, policy_id).

    Parameters
    ----------
    user_id : int
    resource_id : int
    action : str
    env : dict with keys device_trust, network_zone, hour, threat_level
    """
    user = get_user(user_id)
    if not user:
        return "deny", "User not found", None

    resource = get_resource(resource_id)
    if not resource:
        return "deny", "Resource not found", None

    # Pre-fetch extended attributes
    cross_agency = get_user_attribute(user_id, "cross_agency_grant") or "false"
    break_glass = get_user_attribute(user_id, "break_glass_authorized") or "false"

    policies = get_active_policies()

    deny_match = None
    permit_match = None

    for policy in policies:
        # Check target
        trt = policy["target_resource_type"]
        ta = policy["target_action"]
        if trt != "*" and trt != resource["resource_type"]:
            continue
        if ta != "*" and ta != action:
            continue

        # Check all conditions (AND)
        all_met = True
        for cond in policy["conditions"]:
            attr_type = cond["attribute_type"]
            attr_key = cond["attribute_key"]

            # Resolve actual value
            if attr_type == "subject":
                if attr_key == "cross_agency_grant":
                    actual = cross_agency
                elif attr_key == "break_glass_authorized":
                    actual = break_glass
                elif attr_key in user:
                    actual = str(user[attr_key])
                else:
                    actual = get_user_attribute(user_id, attr_key)
            elif attr_type == "resource":
                actual = str(resource.get(attr_key, ""))
            elif attr_type == "environment":
                key_map = {
                    "device_trust": "device_trust",
                    "network_zone": "network_zone",
                    "hour": "hour",
                    "threat_level": "threat_level",
                }
                actual = str(env.get(key_map.get(attr_key, attr_key), ""))
            elif attr_type == "action":
                actual = action
            else:
                actual = None

            expected = _resolve_value(cond["compare_value"], user, resource)

            if not _compare(actual, cond["operator"], expected, cond["value_type"]):
                all_met = False
                break

        if all_met:
            if policy["effect"] == "deny" and deny_match is None:
                deny_match = policy
            elif policy["effect"] == "permit" and permit_match is None:
                permit_match = policy

    # Deny-overrides
    if deny_match:
        return "deny", f"Matched DENY policy: {deny_match['policy_name']}", deny_match["policy_id"]
    if permit_match:
        return "permit", f"Matched PERMIT policy: {permit_match['policy_name']}", permit_match["policy_id"]
    return "deny", "Default deny: no matching permit policy", None
