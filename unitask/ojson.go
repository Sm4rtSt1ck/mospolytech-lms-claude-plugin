package main

// Упорядоченное JSON-дерево: в отличие от map[string]any сохраняет порядок
// ключей и все неизвестные поля, поэтому файл после правки остаётся похожим
// на исходный.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

type Kind int

const (
	KNull Kind = iota
	KBool
	KNumber
	KString
	KArray
	KObject
)

type Field struct {
	Key string
	Val *Node
}

type Node struct {
	Kind   Kind
	Bool   bool
	Num    string
	Str    string
	Items  []*Node
	Fields []Field
}

func NewString(s string) *Node { return &Node{Kind: KString, Str: s} }
func NewNull() *Node           { return &Node{Kind: KNull} }

func Parse(data []byte) (*Node, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	n, err := parseNode(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("лишние данные после JSON")
	}
	return n, nil
}

func parseNode(dec *json.Decoder) (*Node, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			n := &Node{Kind: KObject}
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				k, ok := kt.(string)
				if !ok {
					return nil, fmt.Errorf("ожидался ключ, получено %v", kt)
				}
				v, err := parseNode(dec)
				if err != nil {
					return nil, err
				}
				n.Fields = append(n.Fields, Field{k, v})
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return n, nil
		case '[':
			n := &Node{Kind: KArray}
			for dec.More() {
				v, err := parseNode(dec)
				if err != nil {
					return nil, err
				}
				n.Items = append(n.Items, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return n, nil
		}
	case string:
		return NewString(t), nil
	case json.Number:
		return &Node{Kind: KNumber, Num: string(t)}, nil
	case bool:
		return &Node{Kind: KBool, Bool: t}, nil
	case nil:
		return NewNull(), nil
	}
	return nil, fmt.Errorf("неожиданный токен %v", tok)
}

func (n *Node) Get(k string) *Node {
	if n == nil || n.Kind != KObject {
		return nil
	}
	for _, f := range n.Fields {
		if f.Key == k {
			return f.Val
		}
	}
	return nil
}

func (n *Node) Set(k string, v *Node) {
	for i := range n.Fields {
		if n.Fields[i].Key == k {
			n.Fields[i].Val = v
			return
		}
	}
	n.Fields = append(n.Fields, Field{k, v})
}

func (n *Node) Delete(k string) {
	out := n.Fields[:0]
	for _, f := range n.Fields {
		if f.Key != k {
			out = append(out, f)
		}
	}
	n.Fields = out
}

// Text – значение для показа: строки без кавычек, null – пусто,
// массивы и объекты – компактным JSON.
func (n *Node) Text() string {
	if n == nil {
		return ""
	}
	switch n.Kind {
	case KNull:
		return ""
	case KString:
		return n.Str
	case KNumber:
		return n.Num
	case KBool:
		if n.Bool {
			return "true"
		}
		return "false"
	}
	return n.Compact()
}

// AllText собирает все скалярные значения – для поиска.
func (n *Node) AllText(b *strings.Builder) {
	switch n.Kind {
	case KArray:
		for _, it := range n.Items {
			it.AllText(b)
		}
	case KObject:
		for _, f := range n.Fields {
			f.Val.AllText(b)
		}
	default:
		b.WriteString(n.Text())
		b.WriteByte(' ')
	}
}

func (n *Node) Marshal() []byte {
	var b bytes.Buffer
	n.write(&b, 0)
	b.WriteByte('\n')
	return b.Bytes()
}

func (n *Node) Pretty() string {
	return strings.TrimRight(string(n.Marshal()), "\n")
}

func (n *Node) Compact() string {
	var b bytes.Buffer
	n.writeCompact(&b)
	return b.String()
}

func (n *Node) write(b *bytes.Buffer, lvl int) {
	switch n.Kind {
	case KArray:
		if len(n.Items) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteString("[\n")
		for i, it := range n.Items {
			indent(b, lvl+1)
			it.write(b, lvl+1)
			if i < len(n.Items)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		indent(b, lvl)
		b.WriteByte(']')
	case KObject:
		if len(n.Fields) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		for i, f := range n.Fields {
			indent(b, lvl+1)
			writeString(b, f.Key)
			b.WriteString(": ")
			f.Val.write(b, lvl+1)
			if i < len(n.Fields)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		indent(b, lvl)
		b.WriteByte('}')
	default:
		n.writeCompact(b)
	}
}

func (n *Node) writeCompact(b *bytes.Buffer) {
	switch n.Kind {
	case KNull:
		b.WriteString("null")
	case KBool:
		if n.Bool {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case KNumber:
		b.WriteString(n.Num)
	case KString:
		writeString(b, n.Str)
	case KArray:
		b.WriteByte('[')
		for i, it := range n.Items {
			if i > 0 {
				b.WriteString(", ")
			}
			it.writeCompact(b)
		}
		b.WriteByte(']')
	case KObject:
		b.WriteByte('{')
		for i, f := range n.Fields {
			if i > 0 {
				b.WriteString(", ")
			}
			writeString(b, f.Key)
			b.WriteString(": ")
			f.Val.writeCompact(b)
		}
		b.WriteByte('}')
	}
}

func indent(b *bytes.Buffer, lvl int) {
	for i := 0; i < lvl; i++ {
		b.WriteString("  ")
	}
}

func writeString(b *bytes.Buffer, s string) {
	var tmp bytes.Buffer
	enc := json.NewEncoder(&tmp)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	b.Write(bytes.TrimRight(tmp.Bytes(), "\n"))
}
