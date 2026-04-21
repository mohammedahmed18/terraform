// Copyright IBM Corp. 2014, 2026
// SPDX-License-Identifier: BUSL-1.1

package deprecation

import (
	"fmt"
	"strings"

	"github.com/hashicorp/terraform/internal/configs/configschema"
	"github.com/hashicorp/terraform/internal/lang/format"
	"github.com/hashicorp/terraform/internal/lang/marks"
	"github.com/zclconf/go-cty/cty"
)

// MarkDeprecatedValues inspects the given cty.Value according to the given
// configschema.Block schema, and marks any deprecated attributes or blocks
// found within the value with deprecation marks.
// It works based on the given cty.Value's structure matching the given schema.
func MarkDeprecatedValues(val cty.Value, schema *configschema.Block, origin string) cty.Value {
	if schema == nil {
		return val
	}
	newVal := val

	// Check if the block is deprecated
	if schema.Deprecated {
		newVal = newVal.Mark(marks.NewDeprecation(schemaDeprecationMessage(schema), origin))
	}

	if !newVal.IsKnown() {
		return newVal
	}

	// Fast path: if no attributes or nested blocks in this schema are
	// deprecated, skip the expensive cty.Transform deep walk entirely.
	// This is the common case for most provider resources.
	if !schemaHasDeprecations(schema) {
		return newVal
	}

	// Even if the block itself is not deprecated, its attributes might be
	// deprecated as well
	if val.Type().IsObjectType() || val.Type().IsMapType() || val.Type().IsCollectionType() {
		// We ignore the error, so errors are not allowed in the transform function
		newVal, _ = cty.Transform(newVal, func(p cty.Path, v cty.Value) (cty.Value, error) {

			attr := schema.AttributeByPath(p)
			if attr != nil && attr.Deprecated {
				v = v.Mark(marks.NewDeprecation(attributeDeprecationMessage(attr, p), fmt.Sprintf("%s%s", origin, format.CtyPath(p))))
			}

			nestedBlock := schema.NestedBlockByPath(p)
			if nestedBlock != nil && nestedBlock.Deprecated {
				v = v.Mark(marks.NewDeprecation(blockDeprecationMessage(&nestedBlock.Block, p), fmt.Sprintf("%s%s", origin, format.CtyPath(p))))
			}

			return v, nil
		})
	}

	return newVal
}

// schemaHasDeprecations returns true if any attribute or nested block in the
// schema tree is marked as deprecated. This allows callers to skip expensive
// deep value walks when no deprecations exist.
func schemaHasDeprecations(schema *configschema.Block) bool {
	for _, attr := range schema.Attributes {
		if attr.Deprecated {
			return true
		}
		if attr.NestedType != nil && objectHasDeprecations(attr.NestedType) {
			return true
		}
	}
	for _, bt := range schema.BlockTypes {
		if bt.Deprecated {
			return true
		}
		if schemaHasDeprecations(&bt.Block) {
			return true
		}
	}
	return false
}

// objectHasDeprecations checks a nested object type for deprecated attributes.
func objectHasDeprecations(obj *configschema.Object) bool {
	for _, attr := range obj.Attributes {
		if attr.Deprecated {
			return true
		}
		if attr.NestedType != nil && objectHasDeprecations(attr.NestedType) {
			return true
		}
	}
	return false
}

func schemaDeprecationMessage(schema *configschema.Block) string {
	if schema.DeprecationMessage != "" {
		return schema.DeprecationMessage
	}
	return "Deprecated resource used as value. Refer to the provider documentation for details."
}

func attributeDeprecationMessage(attr *configschema.Attribute, path cty.Path) string {
	if attr.DeprecationMessage != "" {
		return attr.DeprecationMessage
	}
	return fmt.Sprintf("Deprecated resource attribute %q used. Refer to the provider documentation for details.", strings.TrimPrefix(format.CtyPath(path), "."))
}

func blockDeprecationMessage(block *configschema.Block, path cty.Path) string {
	if block.DeprecationMessage != "" {
		return block.DeprecationMessage
	}
	return fmt.Sprintf("Deprecated resource block %q used. Refer to the provider documentation for details.", strings.TrimPrefix(format.CtyPath(path), "."))
}
